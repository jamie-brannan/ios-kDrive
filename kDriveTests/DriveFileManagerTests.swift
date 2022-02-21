/*
 Infomaniak kDrive - iOS App
 Copyright (C) 2021 Infomaniak Network SA

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import InfomaniakCore
import InfomaniakLogin
import kDriveCore
import RealmSwift
import XCTest

@testable import kDrive

final class DriveFileManagerTests: XCTestCase {
    static let defaultTimeout = 10.0
    static var driveFileManager: DriveFileManager!

    override class func setUp() {
        super.setUp()
        let drive = DriveInfosManager.instance.getDrive(id: Env.driveId, userId: Env.userId)!
        driveFileManager = AccountManager.instance.getDriveFileManager(for: drive)
        driveFileManager.apiFetcher.setToken(ApiToken(accessToken: Env.token, expiresIn: Int.max, refreshToken: "", scope: "", tokenType: "", userId: Env.userId, expirationDate: Date(timeIntervalSinceNow: TimeInterval(Int.max))), delegate: FakeTokenDelegate())
    }

    // MARK: - Tests setup

    func setUpTest(testName: String) async throws -> File {
        let rootDirectory = try await getRootDirectory()
        return try await createTestDirectory(name: "UnitTest - \(testName)", parentDirectory: rootDirectory)
    }

    func setUpTest(testName: String, completion: @escaping (File) -> Void) {
        Task {
            try await completion(setUpTest(testName: testName))
        }
    }

    func tearDownTest(directory: File) {
        Task {
            _ = try await DriveFileManagerTests.driveFileManager.delete(file: directory)
        }
    }

    // MARK: - Helping methods

    func getRootDirectory() async throws -> File {
        try await DriveFileManagerTests.driveFileManager.file(id: DriveFileManager.constants.rootID)
    }

    func createTestDirectory(name: String, parentDirectory: File) async throws -> File {
        try await DriveFileManagerTests.driveFileManager.createDirectory(in: parentDirectory, name: "\(name) - \(Date())", onlyForMe: true)
    }

    func createTestDirectory(name: String, parentDirectory: File, completion: @escaping (File) -> Void) {
        Task {
            try await completion(createTestDirectory(name: name, parentDirectory: parentDirectory))
        }
    }

    func initOfficeFile(testName: String) async throws -> (File, File) {
        let testDirectory = try await setUpTest(testName: testName)
        let file = try await DriveFileManagerTests.driveFileManager.createFile(in: testDirectory, name: "officeFile-\(Date())", type: "docx")
        return (testDirectory, file)
    }

    func initOfficeFile(testName: String, completion: @escaping (File, File) -> Void) {
        Task {
            let (testDirectory, file) = try await initOfficeFile(testName: testName)
            completion(testDirectory, file)
        }
    }

    func checkIfFileIsInFavorites(file: File, shouldBePresent: Bool = true) async throws {
        let (favorites, _) = try await DriveFileManagerTests.driveFileManager.favorites()
        let isInFavoritesFiles = favorites.contains { $0.id == file.id }
        XCTAssertEqual(isInFavoritesFiles, shouldBePresent, "File should\(shouldBePresent ? "" : ",'t") be in favorites files")
    }

    func checkIfFileIsInDestination(file: File, destination: File) {
        let cachedFile = DriveFileManagerTests.driveFileManager.getCachedFile(id: file.id)
        XCTAssertNotNil(cachedFile, TestsMessages.notNil("cached file"))
        XCTAssertEqual(destination.id, cachedFile!.parentId, "Parent is different from expected destination")
    }

    // MARK: - Test methods

    func testGetRootFile() async throws {
        _ = try await DriveFileManagerTests.driveFileManager.file(id: DriveFileManager.constants.rootID)
    }

    func testGetCommonDocuments() async throws {
        _ = try await DriveFileManagerTests.driveFileManager.file(id: Env.commonDocumentsId)
    }

    func testFavorites() async throws {
        let testDirectory = try await setUpTest(testName: "Set favorite")
        try await DriveFileManagerTests.driveFileManager.setFavorite(file: testDirectory, favorite: true)
        try await checkIfFileIsInFavorites(file: testDirectory)
        try await DriveFileManagerTests.driveFileManager.setFavorite(file: testDirectory, favorite: false)
        try await checkIfFileIsInFavorites(file: testDirectory, shouldBePresent: false)
        tearDownTest(directory: testDirectory)
    }

    func testShareLink() async throws {
        let testDirectory = try await setUpTest(testName: "Share link")
        _ = try await DriveFileManagerTests.driveFileManager.createShareLink(for: testDirectory)
        let response = try await DriveFileManagerTests.driveFileManager.removeShareLink(for: testDirectory)
        XCTAssertTrue(response, TestsMessages.shouldReturnTrue)
        tearDownTest(directory: testDirectory)
    }

    func testSearchFile() async throws {
        let (testDirectory, file) = try await initOfficeFile(testName: "Search file")
        let (files, _) = try await DriveFileManagerTests.driveFileManager.searchFile(query: file.name, categories: [], belongToAllCategories: true, page: 1, sortType: .nameAZ)
        let searchedFile = files.contains { $0.id == file.id }
        XCTAssertTrue(searchedFile, TestsMessages.notNil("searched file"))
        tearDownTest(directory: testDirectory)
    }

    func testFileAvailableOffline() {
        let testName = "Available offline"
        let expectations = [
            (name: "Set available offline", expectation: XCTestExpectation(description: "Set available offline")),
            (name: "Get available offline", expectation: XCTestExpectation(description: "Get available offline"))
        ]
        var rootFile = File()

        initOfficeFile(testName: testName) { root, officeFile in
            rootFile = root
            DriveFileManagerTests.driveFileManager.setFileAvailableOffline(file: officeFile, available: true) { error in
                XCTAssertNil(error, TestsMessages.noError)
                expectations[0].expectation.fulfill()
                let offlineFiles = DriveFileManagerTests.driveFileManager.getAvailableOfflineFiles()
                let availableOffline = offlineFiles.contains { $0.id == officeFile.id }
                XCTAssertTrue(availableOffline, "New offline file should be in list")
                expectations[1].expectation.fulfill()
            }
        }

        wait(for: expectations.map(\.expectation), timeout: DriveFileManagerTests.defaultTimeout)
        tearDownTest(directory: rootFile)
    }

    func testGetLastModifiedFiles() async throws {
        let testDirectory = try await setUpTest(testName: "Get last modified files")
        let file = try await DriveFileManagerTests.driveFileManager.createFile(in: testDirectory, name: "test", type: "docx")
        let (lastModifiedFiles, _) = try await DriveFileManagerTests.driveFileManager.lastModifiedFiles()
        XCTAssertEqual(lastModifiedFiles.first?.id, file.id, "Last modified file should be root file")
        tearDownTest(directory: testDirectory)
    }

    func testUndoAction() async throws {
        let (testDirectory, file) = try await initOfficeFile(testName: "Undo action")
        let directory = try await DriveFileManagerTests.driveFileManager.createDirectory(in: testDirectory, name: "directory", onlyForMe: true)
        let (moveResponse, _) = try await DriveFileManagerTests.driveFileManager.move(file: file, to: directory)
        try await DriveFileManagerTests.driveFileManager.undoAction(cancelId: moveResponse.id)
        checkIfFileIsInDestination(file: file, destination: testDirectory)
        tearDownTest(directory: testDirectory)
    }

    func testDeleteFile() async throws {
        let (testDirectory, officeFile) = try await initOfficeFile(testName: "Delete file")
        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: officeFile.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("cached file"))
        _ = try await DriveFileManagerTests.driveFileManager.delete(file: officeFile)
        tearDownTest(directory: testDirectory)
    }

    func testMoveFile() async throws {
        let (testDirectory, officeFile) = try await initOfficeFile(testName: "Move file")
        let destination = try await createTestDirectory(name: "Destination", parentDirectory: testDirectory)
        let (_, file) = try await DriveFileManagerTests.driveFileManager.move(file: officeFile, to: destination)
        XCTAssertEqual(file.parent?.id, destination.id, "New parent should be 'destination' directory")

        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: officeFile.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("cached file"))
        XCTAssertEqual(cached?.parent?.id, destination.id, "New parent not updated in realm")
        tearDownTest(directory: testDirectory)
    }

    func testRenameFile() async throws {
        let (testDirectory, officeFile) = try await initOfficeFile(testName: "Rename file")
        let newName = "renamed office file"
        let renamedFile = try await DriveFileManagerTests.driveFileManager.rename(file: officeFile, newName: newName)
        XCTAssertEqual(renamedFile.name, newName, "File name should have been renamed")

        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: officeFile.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("cached file"))
        XCTAssertEqual(cached!.name, newName, "New name not updated in realm")
        tearDownTest(directory: testDirectory)
    }

    func testDuplicateFile() async throws {
        let (testDirectory, officeFile) = try await initOfficeFile(testName: "Duplicate file")
        let duplicateFile = try await DriveFileManagerTests.driveFileManager.duplicate(file: officeFile, duplicateName: "Duplicated file")

        let cachedRoot = DriveFileManagerTests.driveFileManager.getCachedFile(id: testDirectory.id)
        XCTAssertEqual(cachedRoot!.children.count, 2, "Cached root should have 2 children")

        let newFile = cachedRoot?.children.contains { $0.id == duplicateFile.id }
        XCTAssertNotNil(newFile, "New file should be in realm")
        tearDownTest(directory: testDirectory)
    }

    func testCreateDirectory() async throws {
        let testDirectory = try await setUpTest(testName: "Create directory")
        let directory = try await DriveFileManagerTests.driveFileManager.createDirectory(in: testDirectory, name: "Test directory", onlyForMe: true)
        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: directory.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("cached root"))
        tearDownTest(directory: testDirectory)
    }

    func testCategory() async throws {
        let category = try await DriveFileManagerTests.driveFileManager.createCategory(name: "Category-\(Date())", color: "#001227").freeze()
        let categoryId = category.id
        let editedCategory = try await DriveFileManagerTests.driveFileManager.edit(category: category, name: category.name, color: "#314159")
        XCTAssertEqual(categoryId, editedCategory.id, "Category id should be the same")
        let response = try await DriveFileManagerTests.driveFileManager.delete(category: category)
        XCTAssertTrue(response, TestsMessages.shouldReturnTrue)
    }

    func testCategoriesAndFiles() async throws {
        let (testDirectory, officeFile) = try await initOfficeFile(testName: "Categories and files")
        let category = try await DriveFileManagerTests.driveFileManager.createCategory(name: "testCategory-\(Date())", color: "#001227").freeze()
        try await DriveFileManagerTests.driveFileManager.add(category: category, to: officeFile)
        let fileWithCategory = DriveFileManagerTests.driveFileManager.getCachedFile(id: officeFile.id)
        XCTAssertTrue(fileWithCategory!.categories.contains { $0.categoryId == category.id }, "File should contain category")
        try await DriveFileManagerTests.driveFileManager.remove(category: category, from: officeFile)
        let fileWithoutCategory = DriveFileManagerTests.driveFileManager.getCachedFile(id: officeFile.id)
        XCTAssertFalse(fileWithoutCategory!.categories.contains { $0.categoryId == category.id }, "File should not contain category")
        let response = try await DriveFileManagerTests.driveFileManager.delete(category: category)
        XCTAssertTrue(response, TestsMessages.shouldReturnTrue)
        tearDownTest(directory: testDirectory)
    }

    func testCreateCommonDirectory() async throws {
        let directory = try await DriveFileManagerTests.driveFileManager.createCommonDirectory(name: "Create common directory - \(Date())", forAllUser: false)
        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: directory.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("cached root"))
        tearDownTest(directory: directory)
    }

    func testCreateDropBox() async throws {
        let testDirectory = try await setUpTest(testName: "Create dropbox")
        let directory = try await DriveFileManagerTests.driveFileManager.createDropBox(parentDirectory: testDirectory, name: "Test dropbox", onlyForMe: true, settings: DropBoxSettings(alias: nil, emailWhenFinished: true, limitFileSize: nil, password: "mot de passe", validUntil: nil))
        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: directory.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("cached dropbox"))
        XCTAssertNotNil(cached?.dropbox, "Cached dropbox link should be set")
        tearDownTest(directory: testDirectory)
    }

    func testCreateOfficeFile() async throws {
        let testDirectory = try await setUpTest(testName: "Create office file")
        let file = try await DriveFileManagerTests.driveFileManager.createFile(in: testDirectory, name: "Test file", type: "docx")
        let cached = DriveFileManagerTests.driveFileManager.getCachedFile(id: file.id)
        XCTAssertNotNil(cached, TestsMessages.notNil("office file"))
        tearDownTest(directory: testDirectory)
    }
}
