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
import RealmSwift
import CocoaLumberjackSwift
import SwiftRegex
import InfomaniakLogin
import InfomaniakCore

public class DriveFileManager {

    public class DriveFileManagerConstants {
        private let fileManager = FileManager.default
        public let rootDocumentsURL: URL
        public let importDirectoryURL: URL
        public let groupDirectoryURL: URL
        public let cacheDirectoryURL: URL
        public let openInPlaceDirectoryURL: URL?
        public let rootID = 1
        public let currentUploadDbVersion: UInt64 = 3
        public lazy var migrationBlock = { [weak self] (migration: Migration, oldSchemaVersion: UInt64) in
            guard let strongSelf = self else { return }
            if (oldSchemaVersion < strongSelf.currentUploadDbVersion) {
                // Migration from version 2 to version 3
                if oldSchemaVersion < 3 {
                    migration.enumerateObjects(ofType: UploadFile.className()) { (_, newObject) in
                        newObject!["maxRetryCount"] = 3
                    }
                }
            }
        }
        public lazy var uploadsRealmConfiguration = Realm.Configuration(
            fileURL: rootDocumentsURL.appendingPathComponent("/uploads.realm"),
            schemaVersion: currentUploadDbVersion,
            migrationBlock: migrationBlock,
            objectTypes: [DownloadTask.self, UploadFile.self, PhotoSyncSettings.self])

        public var uploadsRealm: Realm {
            return try! Realm(configuration: uploadsRealmConfiguration)
        }

        init() {
            groupDirectoryURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AccountManager.appGroup)!
            rootDocumentsURL = groupDirectoryURL.appendingPathComponent("drives", isDirectory: true)
            importDirectoryURL = groupDirectoryURL.appendingPathComponent("import", isDirectory: true)
            cacheDirectoryURL = groupDirectoryURL.appendingPathComponent("Library/Caches", isDirectory: true)
            openInPlaceDirectoryURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(".shared", isDirectory: true)
            try? fileManager.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: groupDirectoryURL.path)
            try? FileManager.default.createDirectory(atPath: rootDocumentsURL.path, withIntermediateDirectories: true, attributes: nil)
            try? FileManager.default.createDirectory(atPath: importDirectoryURL.path, withIntermediateDirectories: true, attributes: nil)
            try? FileManager.default.createDirectory(atPath: cacheDirectoryURL.path, withIntermediateDirectories: true, attributes: nil)

            DDLogInfo("App working path is: \(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.absoluteString ?? "")")
            DDLogInfo("Group container path is: \(groupDirectoryURL.absoluteString)")
        }
    }

    public static let constants = DriveFileManagerConstants()

    private let fileManager = FileManager.default
    public static var favoriteRootFile: File {
        return File(id: -1, name: "Favorite")
    }
    public static var trashRootFile: File {
        return File(id: -2, name: "Trash")
    }
    public static var sharedWithMeRootFile: File {
        return File(id: -3, name: "Shared with me")
    }
    public static var mySharedRootFile: File {
        return File(id: -4, name: "My shares")
    }
    public static var searchFilesRootFile: File {
        return File(id: -5, name: "Search")
    }
    public static var homeRootFile: File {
        return File(id: -6, name: "Home")
    }
    public static var lastModificationsRootFile: File {
        return File(id: -7, name: "Recent changes")
    }
    public static var lastPicturesRootFile: File {
        return File(id: -8, name: "Images")
    }
    public func getRootFile(using realm: Realm? = nil) -> File {
        if let root = getCachedFile(id: DriveFileManager.constants.rootID, freeze: false) {
            if root.name != drive.name {
                let realm = realm ?? getRealm()
                try? realm.safeWrite {
                    root.name = drive.name
                }
            }
            return root.freeze()
        } else {
            return File(id: DriveFileManager.constants.rootID, name: drive.name)
        }
    }
    let backgroundQueue = DispatchQueue(label: "background-db")
    public var realmConfiguration: Realm.Configuration
    public var drive: Drive
    public var apiFetcher: DriveApiFetcher

    private var didUpdateFileObservers = [UUID: (File) -> Void]()

    init(drive: Drive, apiToken: ApiToken, refreshTokenDelegate: RefreshTokenDelegate) {
        self.drive = drive
        apiFetcher = DriveApiFetcher(drive: drive)
        apiFetcher.setToken(apiToken, authenticator: SyncedAuthenticator(refreshTokenDelegate: refreshTokenDelegate))
        let realmName = "\(drive.userId)-\(drive.id).realm"
        realmConfiguration = Realm.Configuration(
            fileURL: DriveFileManager.constants.cacheDirectoryURL.appendingPathComponent(realmName),
            deleteRealmIfMigrationNeeded: true,
            objectTypes: [File.self, Rights.self, FileActivity.self])

        //Only compact in the background
        if !Constants.isInExtension && UIApplication.shared.applicationState == .background {
            compactRealmsIfNeeded()
        }

        // Get root file
        let realm = getRealm()
        if getCachedFile(id: DriveFileManager.constants.rootID, using: realm) == nil {
            let rootFile = getRootFile(using: realm)
            try? realm.safeWrite {
                realm.add(rootFile)
            }
        }
    }

    private func compactRealmsIfNeeded() {
        DDLogInfo("Trying to compact realms if needed")
        let compactingCondition: (Int, Int) -> (Bool) = { totalBytes, usedBytes in
            let fiftyMB = 50 * 1024 * 1024
            let compactingNeeded = (totalBytes > fiftyMB) && (Double(usedBytes) / Double(totalBytes)) < 0.5
            return compactingNeeded
        }

        let config = Realm.Configuration(
            fileURL: DriveFileManager.constants.rootDocumentsURL.appendingPathComponent("/DrivesInfos.realm"),
            shouldCompactOnLaunch: compactingCondition,
            objectTypes: [Drive.self, DrivePackFunctionality.self, DrivePreferences.self, DriveUsersCategories.self, DriveUser.self, Tag.self])
        do {
            let _ = try Realm(configuration: config)
        } catch {
            DDLogError("Failed to compact drive infos realm: \(error)")
        }

        let files = (try? fileManager.contentsOfDirectory(at: DriveFileManager.constants.cacheDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "realm" {
            do {
                let realmConfiguration = Realm.Configuration(
                    fileURL: file,
                    deleteRealmIfMigrationNeeded: true,
                    shouldCompactOnLaunch: compactingCondition,
                    objectTypes: [File.self, Rights.self, FileActivity.self])
                let _ = try Realm(configuration: realmConfiguration)
            } catch {
                DDLogError("Failed to compact realm: \(error)")
            }
        }
    }

    public func getRealm() -> Realm {
        return try! Realm(configuration: realmConfiguration)
    }

    /// Delete all drive data cache for a user
    /// - Parameters:
    ///   - userId: User ID
    ///   - driveId: Drive ID (`nil` if all user drives)
    public static func deleteUserDriveFiles(userId: Int, driveId: Int? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: DriveFileManager.constants.cacheDirectoryURL, includingPropertiesForKeys: nil))
        files?.forEach { file in
            if let matches = Regex(pattern: "(\\d+)-(\\d+).realm.*")?.firstMatch(in: file.lastPathComponent), matches.count > 2 {
                let fileUserId = matches[1]
                let fileDriveId = matches[2]
                if Int(fileUserId) == userId && (driveId == nil || Int(fileDriveId) == driveId) {
                    DDLogInfo("Deleting file: \(file.lastPathComponent)")
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    public func getCachedFile(id: Int, freeze: Bool = true, using realm: Realm? = nil) -> File? {
        let realm = realm ?? getRealm()
        let file = realm.object(ofType: File.self, forPrimaryKey: id)
        return freeze ? file?.freeze() : file
    }

    public func getFile(id: Int, withExtras: Bool = false, page: Int = 1, sortType: SortType = .nameAZ, forceRefresh: Bool = false, completion: @escaping (File?, [File]?, Error?) -> Void) {
        let realm = getRealm()
        if var cachedFile = realm.object(ofType: File.self, forPrimaryKey: id),
            //We have cache and we show it before fetching activities OR we are not connected to internet and we show what we have anyway
            (cachedFile.fullyDownloaded && !forceRefresh && cachedFile.responseAt > 0 && !withExtras) || ReachabilityListener.instance.currentStatus == .offline {
            //Sometimes realm isn't up to date
            realm.refresh()
            cachedFile = cachedFile.freeze()
            backgroundQueue.async {
                let sortedChildren = self.getLocalSortedDirectoryFiles(directory: cachedFile, sortType: sortType)
                DispatchQueue.main.async {
                    completion(cachedFile, sortedChildren, nil)
                }
            }
        } else {
            if !withExtras {
                apiFetcher.getFileListForDirectory(parentId: id, page: page, sortType: sortType) { [self] (response, error) in
                    if let file = response?.data {
                        backgroundQueue.async {
                            autoreleasepool {
                                if file.id == DriveFileManager.constants.rootID {
                                    file.name = drive.name
                                }
                                file.responseAt = response?.responseAt ?? 0

                                let localRealm = getRealm()
                                keepCacheAttributesForFile(newFile: file, keepStandard: false, keepExtras: true, keepRights: false, using: localRealm)
                                for child in file.children {
                                    keepCacheAttributesForFile(newFile: child, keepStandard: true, keepExtras: true, keepRights: false, using: localRealm)
                                }

                                if file.children.count < DriveApiFetcher.itemPerPage {
                                    file.fullyDownloaded = true
                                }

                                do {
                                    var updatedFile: File!

                                    if page > 1 {
                                        //Only 25 children are returned by the API, we have to add the previous children to our file
                                        updatedFile = try self.updateFileChildrenInDatabase(file: file, using: localRealm)
                                    } else {
                                        //No children, we only update file in db
                                        updatedFile = try self.updateFileInDatabase(updatedFile: file, using: localRealm)
                                    }

                                    let safeFile = ThreadSafeReference(to: updatedFile)
                                    let sortedChildren = getLocalSortedDirectoryFiles(directory: updatedFile, sortType: sortType)
                                    DispatchQueue.main.async {
                                        completion(realm.resolve(safeFile), sortedChildren, nil)
                                    }
                                } catch {
                                    DispatchQueue.main.async {
                                        completion(nil, nil, error)
                                    }
                                }
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(nil, nil, error)
                        }
                    }
                }
            } else {
                apiFetcher.getFileDetail(fileId: id) { [self] (response, error) in
                    if let file = response?.data {
                        keepCacheAttributesForFile(newFile: file, keepStandard: true, keepExtras: false, keepRights: false, using: realm)

                        try? realm.safeWrite {
                            realm.add(file, update: .modified)
                        }

                        let returnedFile = file.freeze()
                        DispatchQueue.main.async {
                            completion(returnedFile, [], error)
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(nil, nil, error)
                        }
                    }
                }
            }
        }
    }

    public func getFavorites(page: Int = 1, sortType: SortType = .nameAZ, forceRefresh: Bool = false, completion: @escaping (File?, [File]?, Error?) -> Void) {
        apiFetcher.getFavoriteFiles(page: page) { [self] (response, error) in
            if let favorites = response?.data {
                backgroundQueue.async {
                    autoreleasepool {
                        let localRealm = getRealm()
                        for favorite in favorites {
                            keepCacheAttributesForFile(newFile: favorite, keepStandard: true, keepExtras: true, keepRights: false, using: localRealm)
                        }

                        let favoritesRoot = DriveFileManager.favoriteRootFile
                        if favorites.count < DriveApiFetcher.itemPerPage {
                            favoritesRoot.fullyDownloaded = true
                        }

                        do {
                            var updatedFile: File!

                            favoritesRoot.children.append(objectsIn: favorites)
                            updatedFile = try self.updateFileInDatabase(updatedFile: favoritesRoot, using: localRealm)

                            let safeFile = ThreadSafeReference(to: updatedFile)
                            let sortedChildren = getLocalSortedDirectoryFiles(directory: updatedFile, sortType: sortType)
                            DispatchQueue.main.async {
                                completion(getRealm().resolve(safeFile), sortedChildren, nil)
                            }
                        } catch {
                            DispatchQueue.main.async {
                                completion(nil, nil, error)
                            }
                        }
                    }
                }
            } else {
                completion(nil, nil, error)
            }
        }
    }

    public func getMyShared(page: Int = 1, sortType: SortType = .nameAZ, forceRefresh: Bool = false, completion: @escaping (File?, [File]?, Error?) -> Void) {
        apiFetcher.getMyShared(page: page, sortType: sortType) { [self] (response, error) in
            let realm = getRealm()
            let mySharedRoot = DriveFileManager.mySharedRootFile
            if let sharedFiles = response?.data {
                backgroundQueue.async {
                    autoreleasepool {
                        let localRealm = getRealm()
                        for sharedFile in sharedFiles {
                            keepCacheAttributesForFile(newFile: sharedFile, keepStandard: true, keepExtras: true, keepRights: false, using: localRealm)
                        }

                        if sharedFiles.count < DriveApiFetcher.itemPerPage {
                            mySharedRoot.fullyDownloaded = true
                        }

                        do {
                            var updatedFile: File!

                            mySharedRoot.children.append(objectsIn: sharedFiles)
                            updatedFile = try self.updateFileInDatabase(updatedFile: mySharedRoot, using: localRealm)

                            let safeFile = ThreadSafeReference(to: updatedFile)
                            let sortedChildren = getLocalSortedDirectoryFiles(directory: updatedFile, sortType: sortType)
                            DispatchQueue.main.async {
                                completion(realm.resolve(safeFile), sortedChildren, nil)
                            }
                        } catch {
                            DispatchQueue.main.async {
                                completion(nil, nil, error)
                            }
                        }
                    }
                }
            } else {
                if page == 1 {
                    if let parent = realm.object(ofType: File.self, forPrimaryKey: mySharedRoot.id) {
                        var allFiles = [File]()
                        let searchResult = parent.children.sorted(byKeyPath: sortType.value.realmKeyPath, ascending: sortType.value.order == "asc")
                        for child in searchResult.freeze() { allFiles.append(child.freeze()) }

                        mySharedRoot.fullyDownloaded = true
                        completion(mySharedRoot, allFiles, error)
                    }
                }
                completion(nil, nil, error)
            }
        }
    }

    public func getAvailableOfflineFiles(sortType: SortType = .nameAZ) -> [File] {
        let offlineFiles = getRealm().objects(File.self)
            .filter(NSPredicate(format: "isAvailableOffline = true"))
            .sorted(byKeyPath: sortType.value.realmKeyPath, ascending: sortType.value.order == "asc").freeze()

        return offlineFiles.map { $0.freeze() }
    }

    public func getLocalSortedDirectoryFiles(directory: File, sortType: SortType) -> [File] {
        let children = directory.freeze().children.sorted(byKeyPath: sortType.value.realmKeyPath, ascending: sortType.value.order == "asc")

        let teamSpaces = children.filter(NSPredicate(format: "rawVisibility = %@", VisibilityType.isTeamSpace.rawValue))
        let sharedSpaces = children.filter(NSPredicate(format: "rawVisibility = %@", VisibilityType.isSharedSpace.rawValue))
        let dirs = children.filter(
            NSPredicate(format: "rawVisibility != %@ AND rawVisibility != %@ AND type = %@",
                VisibilityType.isTeamSpace.rawValue,
                VisibilityType.isSharedSpace.rawValue,
                "dir")
        )
        let files = children.filter(NSPredicate(format: "type = %@", "file"))

        var allFiles = [File]()
        for child in teamSpaces { allFiles.append(child.freeze()) }
        for child in sharedSpaces { allFiles.append(child.freeze()) }
        for child in dirs { allFiles.append(child.freeze()) }
        for child in files { allFiles.append(child.freeze()) }

        return allFiles
    }

    public func searchFile(query: String? = nil, fileType: String? = nil, page: Int = 1, sortType: SortType = .nameAZ, completion: @escaping (File?, [File]?, Error?) -> Void) {
        if ReachabilityListener.instance.currentStatus == .offline {
            searchOffline(query: query, fileType: fileType, sortType: sortType, completion: completion)
        } else {
            apiFetcher.searchFiles(query: query, fileType: fileType, page: page, sortType: sortType) { [self] (response, error) in
                if let files = response?.data {
                    self.backgroundQueue.async { [self] in
                        autoreleasepool {
                            let realm = getRealm()
                            let searchRoot = DriveFileManager.searchFilesRootFile
                            if files.count < DriveApiFetcher.itemPerPage {
                                searchRoot.fullyDownloaded = true
                            }
                            for file in files {
                                keepCacheAttributesForFile(newFile: file, keepStandard: true, keepExtras: true, keepRights: false, using: realm)
                            }

                            setLocalFiles(files, root: searchRoot) {
                                let safeRoot = ThreadSafeReference(to: searchRoot)
                                DispatchQueue.main.async {
                                    completion(getRealm().resolve(safeRoot), files, nil)
                                }
                            }
                        }
                    }
                } else {
                    searchOffline(query: query, fileType: fileType, sortType: sortType, completion: completion)
                }
            }
        }
    }

    private func searchOffline(query: String? = nil, fileType: String? = nil, sortType: SortType = .nameAZ, completion: @escaping (File?, [File]?, Error?) -> Void) {
        let realm = getRealm()
        var searchResults = realm.objects(File.self)
        if let query = query, !query.isBlank() {
            searchResults = searchResults.filter(NSPredicate(format: "name CONTAINS %@", query))
        }
        if let fileType = fileType {
            searchResults = searchResults.filter(NSPredicate(format: "rawConvertedType = %@", fileType))
        }
        var allFiles = [File]()

        if query != nil || fileType != nil {
            searchResults = searchResults.sorted(byKeyPath: sortType.value.realmKeyPath, ascending: sortType.value.order == "asc")
            for child in searchResults.freeze() { allFiles.append(child.freeze()) }
        }

        let searchRoot = DriveFileManager.searchFilesRootFile
        searchRoot.fullyDownloaded = true

        completion(searchRoot, allFiles, DriveError.networkError)
    }

    public func getLocalFile(file: File, page: Int = 1, completion: @escaping (File?, Error?) -> Void) {
        if file.isDirectory {
            completion(nil, nil)
        } else {
            if !file.isLocalVersionOlderThanRemote() {
                //Already up to date, not downloading
                completion(file, nil)
            } else {
                DownloadQueue.instance.observeFileDownloaded(self, fileId: file.id) { _, error in
                    completion(file, error)
                }
                DownloadQueue.instance.addToQueue(file: file, userId: drive.userId)
            }

        }
    }

    public func setFileAvailableOffline(file: File, available: Bool, completion: @escaping (Error?) -> Void) {
        let fileId = file.id
        let realm = getRealm()
        if available {
            updateFileProperty(fileId: fileId, using: realm) { (file) in
                file.isAvailableOffline = true
            }

            if !file.isLocalVersionOlderThanRemote() {
                do {
                    if let updatedFile = getCachedFile(id: fileId, freeze: false) {
                        try fileManager.createDirectory(at: updatedFile.localContainerUrl, withIntermediateDirectories: true)
                        try fileManager.moveItem(at: file.localUrl, to: updatedFile.localUrl)
                        notifyObserversWith(file: updatedFile)
                    }
                    completion(nil)
                } catch {
                    updateFileProperty(fileId: fileId, using: realm) { (file) in
                        file.isAvailableOffline = false
                    }
                    completion(error)
                }
            } else {
                DownloadQueue.instance.observeFileDownloaded(self, fileId: file.id) { _, error in
                    DispatchQueue.main.async {
                        completion(error)
                    }
                }
                DownloadQueue.instance.addToQueue(file: file, userId: drive.userId)
            }
        } else {
            updateFileProperty(fileId: fileId, using: realm) { (file) in
                file.isAvailableOffline = false
            }
            if let updatedFile = getCachedFile(id: fileId, freeze: false, using: realm) {
                try? fileManager.createDirectory(at: updatedFile.localContainerUrl, withIntermediateDirectories: true)
                try? fileManager.moveItem(at: file.localUrl, to: updatedFile.localUrl)
                notifyObserversWith(file: updatedFile)
            }
            try? fileManager.removeItem(at: file.localContainerUrl)
            completion(nil)
        }
    }

    public func setFileShareLink(file: File, shareLink: String?) -> File? {
        let realm = getRealm()
        let file = realm.object(ofType: File.self, forPrimaryKey: file.id)
        try? realm.write {
            file?.shareLink = shareLink
            file?.rights?.canBecomeLink.value = shareLink == nil
        }
        if let file = file {
            notifyObserversWith(file: file)
        }
        return file
    }

    public func getLocalRecentActivities() -> [FileActivity] {
        return Array(getRealm().objects(FileActivity.self).sorted(byKeyPath: "createdAt", ascending: false).freeze())
    }

    public func setLocalRecentActivities(_ activities: [FileActivity]) {
        backgroundQueue.async { [self] in
            let realm = getRealm()
            let homeRootFile = DriveFileManager.homeRootFile
            var activitiesSafe = [FileActivity]()
            for activity in activities {
                let safeActivity = FileActivity(value: activity)
                if let file = activity.file {
                    let safeFile = File(value: file)
                    keepCacheAttributesForFile(newFile: safeFile, keepStandard: true, keepExtras: true, keepRights: true, using: realm)
                    homeRootFile.children.append(safeFile)
                    safeActivity.file = safeFile
                    if let rights = file.rights {
                        safeActivity.file?.rights = Rights(value: rights)
                    }
                }
                activitiesSafe.append(safeActivity)
            }

            try? realm.safeWrite {
                realm.delete(realm.objects(FileActivity.self))
                //Delete orphan files which are NOT root
                deleteOrphanFiles(root: DriveFileManager.homeRootFile, using: realm)

                realm.add(activitiesSafe, update: .modified)
                realm.add(homeRootFile, update: .modified)
            }
        }
    }

    public func setLocalFiles(_ files: [File], root: File, completion: (() -> Void)? = nil) {
        backgroundQueue.async { [self] in
            autoreleasepool {
                let realm = getRealm()
                for file in files {
                    let safeFile = File(value: file)
                    keepCacheAttributesForFile(newFile: safeFile, keepStandard: true, keepExtras: true, keepRights: true, using: realm)
                    root.children.append(safeFile)
                    if let rights = file.rights {
                        safeFile.rights = Rights(value: rights)
                    }
                }

            try? realm.safeWrite {
                //Delete orphan files which are NOT root
                deleteOrphanFiles(root: root, using: realm)

                    realm.add(root, update: .modified)
                }
            }
            completion?()
        }
    }

    public func getLastModifiedFiles(page: Int? = nil, completion: @escaping ([File]?, Error?) -> Void) {
        apiFetcher.getLastModifiedFiles(page: page) { (response, error) in
            if let files = response?.data {
                self.backgroundQueue.async { [self] in
                    autoreleasepool {
                        let realm = getRealm()
                        for file in files {
                            keepCacheAttributesForFile(newFile: file, keepStandard: true, keepExtras: true, keepRights: false, using: realm)
                        }

                        setLocalFiles(files, root: DriveFileManager.lastModificationsRootFile)
                        DispatchQueue.main.async {
                            completion(files, nil)
                        }
                    }
                }
            } else {
                completion(nil, error)
            }
        }
    }

    public func getLastPictures(page: Int = 1, completion: @escaping ([File]?, Error?) -> Void) {
        apiFetcher.getLastPictures(page: page) { (response, error) in
            if let files = response?.data {
                self.backgroundQueue.async { [self] in
                    autoreleasepool {
                        let realm = getRealm()
                        for file in files {
                            keepCacheAttributesForFile(newFile: file, keepStandard: true, keepExtras: true, keepRights: false, using: realm)
                        }

                        setLocalFiles(files, root: DriveFileManager.lastPicturesRootFile)
                        DispatchQueue.main.async {
                            completion(files, nil)
                        }
                    }
                }
            } else {
                completion(nil, error)
            }
        }
    }

    public func getFolderActivities(file: File,
        date: Int? = nil,
        pagedActions: [Int: FileActivityType]? = nil,
        pagedActivities: (inserted: [File], updated: [File], deleted: [File]) = (inserted: [File](), updated: [File](), deleted: [File]()),
        page: Int = 1,
        completion: @escaping ((inserted: [File], updated: [File], deleted: [File])?, Int?, Error?) -> Void) {
        var pagedActions = pagedActions ?? [Int: FileActivityType]()
        let fromDate = date ?? file.responseAt
        let safeFile = ThreadSafeReference(to: file)
        apiFetcher.getFileActivitiesFromDate(file: file, date: fromDate, page: page) { (response, error) in
            if let activities = response?.data,
                let timestamp = response?.responseAt {
                self.backgroundQueue.async { [self] in
                    let realm = getRealm()
                    guard let file = realm.resolve(safeFile) else {
                        DispatchQueue.main.async {
                            completion(nil, nil, nil)
                        }
                        return
                    }

                    var results = applyFolderActivitiesTo(file: file, activities: activities, pagedActions: &pagedActions, timestamp: timestamp, using: realm)
                    results.inserted.append(contentsOf: pagedActivities.inserted)
                    results.updated.append(contentsOf: pagedActivities.updated)
                    results.deleted.append(contentsOf: pagedActivities.deleted)

                    if activities.count < DriveApiFetcher.itemPerPage {
                        DispatchQueue.main.async {
                            completion(results, response?.responseAt, nil)
                        }
                    } else {
                        getFolderActivities(file: file, date: fromDate, pagedActions: pagedActions, pagedActivities: results, page: page + 1, completion: completion)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil, nil, error)
                }
            }
        }
    }

    private func applyFolderActivitiesTo(file: File,
        activities: [FileActivity],
        pagedActions: inout [Int: FileActivityType],
        timestamp: Int,
        using realm: Realm? = nil) -> (inserted: [File], updated: [File], deleted: [File]) {
        var insertedFiles = [File]()
        var updatedFiles = [File]()
        var deletedFiles = [File]()
        let realm = realm ?? getRealm()
        realm.beginWrite()
        for activity in activities {
            let fileId = activity.fileId
            if pagedActions[fileId] == nil {
                switch activity.action {
                case .fileDelete, .fileMoveOut, .fileTrash:
                    if let file = realm.object(ofType: File.self, forPrimaryKey: fileId) {
                        deletedFiles.append(file.freeze())
                    }
                    removeFileInDatabase(fileId: fileId, cascade: true, withTransaction: false, using: realm)
                    if let file = activity.file {
                        deletedFiles.append(file)
                    }
                    pagedActions[fileId] = .fileDelete
                case .fileRename:
                    if let oldFile = realm.object(ofType: File.self, forPrimaryKey: fileId),
                        let renamedFile = activity.file {
                        try? renameCachedFile(updatedFile: renamedFile, oldFile: oldFile)
                        //If the file is a folder we have to copy the old attributes which are not returned by the API
                        keepCacheAttributesForFile(newFile: renamedFile, keepStandard: true, keepExtras: true, keepRights: false, using: realm)

                        realm.add(renamedFile, update: .modified)
                        if !file.children.contains(renamedFile) {
                            file.children.append(renamedFile.freeze())
                        }
                        renamedFile.applyLastModifiedDateToLocalFile()
                        updatedFiles.append(File(value: renamedFile))
                        pagedActions[fileId] = .fileUpdate
                    }
                case .fileFavoriteCreate:
                    if let file = realm.object(ofType: File.self, forPrimaryKey: fileId) {
                        file.isFavorite = true
                        updatedFiles.append(file)
                        pagedActions[fileId] = .fileUpdate
                    }
                case .fileFavoriteRemove:
                    if let file = realm.object(ofType: File.self, forPrimaryKey: fileId) {
                        file.isFavorite = false
                        updatedFiles.append(file.freeze())
                        pagedActions[fileId] = .fileUpdate
                    }
                case .fileMoveIn, .fileRestore, .fileCreate:
                    if let newFile = activity.file {
                        realm.add(newFile, update: .modified)
                        //It shouldn't be necessary to check for duplicates before adding the child
                        if !file.children.contains(newFile) {
                            file.children.append(newFile)
                        }
                        insertedFiles.append(newFile)
                        pagedActions[fileId] = .fileCreate
                    }
                case .fileUpdate, .fileShareCreate, .fileShareUpdate, .fileShareDelete:
                    if let newFile = activity.file {
                        keepCacheAttributesForFile(newFile: newFile, keepStandard: true, keepExtras: true, keepRights: false, using: realm)
                        realm.add(newFile, update: .modified)
                        updatedFiles.append(File(value: newFile))
                        pagedActions[fileId] = .fileUpdate
                    }
                default:
                    break
                }
            }
        }
        file.responseAt = timestamp
        try? realm.commitWrite()
        return (inserted: insertedFiles.map { $0.freeze() }, updated: updatedFiles, deleted: deletedFiles)
    }

    public func getWorkingSet() -> [File] {
        //let predicate = NSPredicate(format: "isFavorite = %d OR lastModifiedAt >= %d", true, Int(Date(timeIntervalSinceNow: -3600).timeIntervalSince1970))
        let files = getRealm().objects(File.self).sorted(byKeyPath: "lastModifiedAt", ascending: false)
        var result = [File]()
        for i in 0..<min(20, files.count) {
            result.append(files[i])
        }
        return result
    }

    public func setFavoriteFile(file: File, favorite: Bool, completion: @escaping (Error?) -> Void) {
        let fileId = file.id
        if favorite {
            apiFetcher.postFavoriteFile(file: file) { (success, error) in
                if error == nil {
                    self.updateFileProperty(fileId: fileId) { file in
                        file.isFavorite = true
                    }
                }
                completion(error)
            }
        } else {
            apiFetcher.deleteFavoriteFile(file: file) { (success, error) in
                if error == nil {
                    self.updateFileProperty(fileId: fileId) { file in
                        file.isFavorite = false
                    }
                }
                completion(error)
            }
        }
    }

    public func deleteFile(file: File, completion: @escaping (CancelableResponse?, Error?) -> Void) {
        let fileId = file.id
        apiFetcher.deleteFile(file: file) { (response, error) in
            if error == nil {
                file.signalChanges()
                self.backgroundQueue.async { [self] in
                    let localRealm = getRealm()
                    removeFileInDatabase(fileId: fileId, cascade: false, withTransaction: true, using: localRealm)
                    DispatchQueue.main.async {
                        completion(response?.data, error)
                    }
                    deleteOrphanFiles(root: DriveFileManager.homeRootFile, DriveFileManager.lastPicturesRootFile, DriveFileManager.lastModificationsRootFile, DriveFileManager.searchFilesRootFile, using: localRealm)
                }
            } else {
                completion(response?.data, error)
            }
        }
    }

    public func moveFile(file: File, newParent: File, completion: @escaping (CancelableResponse?, File?, Error?) -> Void) {
        let safeFile = ThreadSafeReference(to: file)
        let safeParent = ThreadSafeReference(to: newParent)
        apiFetcher.moveFile(file: file, newParent: newParent) { (response, error) in
            if error == nil {
                // Add the moved file to the realm db
                let realm = self.getRealm()
                if let parent = realm.resolve(safeParent),
                    let file = realm.resolve(safeFile),
                    let index = file.parent?.children.index(of: file) {
                    let oldParent = file.parent
                    try? realm.write {
                        file.parent?.children.remove(at: index)
                        parent.children.append(file)
                    }
                    if let oldParent = oldParent {
                        oldParent.signalChanges()
                        self.notifyObserversWith(file: oldParent)
                    }
                    parent.signalChanges()
                    self.notifyObserversWith(file: parent)
                    completion(response?.data, file, error)
                } else {
                    completion(response?.data, nil, error)
                }
            } else {
                completion(nil, nil, error)
            }
        }
    }

    public func renameFile(file: File, newName: String, completion: @escaping (File?, Error?) -> Void) {
        let safeFile = ThreadSafeReference(to: file)
        apiFetcher.renameFile(file: file, newName: newName) { [self] (response, error) in
            let realm = getRealm()
            if let updatedFile = response?.data,
                let file = realm.resolve(safeFile) {
                do {
                    updatedFile.isAvailableOffline = file.isAvailableOffline
                    let updatedFile = try self.updateFileInDatabase(updatedFile: updatedFile, oldFile: file, using: realm)
                    updatedFile.signalChanges()
                    self.notifyObserversWith(file: updatedFile)
                    completion(updatedFile, nil)
                } catch {
                    completion(nil, error)
                }
            } else {
                completion(nil, error)
            }
        }
    }

    public func duplicateFile(file: File, duplicateName: String, completion: @escaping (File?, Error?) -> Void) {
        let parentId = file.parent?.id
        apiFetcher.duplicateFile(file: file, duplicateName: duplicateName) { (response, error) in
            if let duplicateFile = response?.data {
                do {
                    let duplicateFile = try self.updateFileInDatabase(updatedFile: duplicateFile)
                    let realm = duplicateFile.realm
                    let parent = realm?.object(ofType: File.self, forPrimaryKey: parentId)
                    try realm?.safeWrite {
                        parent?.children.append(duplicateFile)
                    }

                    duplicateFile.signalChanges()
                    if let parent = file.parent {
                        parent.signalChanges()
                        self.notifyObserversWith(file: parent)
                    }
                    completion(duplicateFile, nil)
                } catch {
                    completion(nil, error)
                }
            } else {
                completion(nil, error)
            }
        }
    }

    public func createDirectory(parentDirectory: File, name: String, onlyForMe: Bool, completion: @escaping (File?, Error?) -> Void) {
        let parentId = parentDirectory.id
        apiFetcher.createDirectory(parentDirectory: parentDirectory, name: name, onlyForMe: onlyForMe) { (response, error) in
            if let createdDirectory = response?.data {
                do {
                    let createdDirectory = try self.updateFileInDatabase(updatedFile: createdDirectory)
                    let realm = createdDirectory.realm
                    // Add directory to parent
                    let parent = realm?.object(ofType: File.self, forPrimaryKey: parentId)
                    try realm?.safeWrite {
                        parent?.children.append(createdDirectory)
                    }
                    if let parent = createdDirectory.parent {
                        parent.signalChanges()
                        self.notifyObserversWith(file: parent)
                    }
                    completion(createdDirectory, error)
                } catch {
                    completion(nil, error)
                }
            } else {
                completion(nil, error)
            }
        }
    }

    public func createCommonDirectory(name: String, forAllUser: Bool, completion: @escaping (File?, Error?) -> Void) {
        apiFetcher.createCommonDirectory(name: name, forAllUser: forAllUser) { (response, error) in
            if let createdDirectory = response?.data {
                do {
                    let createdDirectory = try self.updateFileInDatabase(updatedFile: createdDirectory)
                    if let parent = createdDirectory.parent {
                        parent.signalChanges()
                        self.notifyObserversWith(file: parent)
                    }
                    completion(createdDirectory, error)
                } catch {
                    completion(nil, error)
                }
            } else {
                completion(nil, error)
            }
        }
    }

    public func createDropBox(parentDirectory: File,
        name: String,
        onlyForMe: Bool,
        password: String?,
        validUntil: Date?,
        emailWhenFinished: Bool,
        limitFileSize: Int?,
        completion: @escaping (File?, DropBox?, Error?) -> Void) {
        let parentId = parentDirectory.id
        apiFetcher.createDirectory(parentDirectory: parentDirectory, name: name, onlyForMe: onlyForMe) { [self] (response, error) in
            if let createdDirectory = response?.data {
                apiFetcher.setupDropBox(directory: createdDirectory, password: password, validUntil: validUntil, emailWhenFinished: emailWhenFinished, limitFileSize: limitFileSize) { (response, error) in
                    if let dropbox = response?.data {
                        do {
                            let createdDirectory = try self.updateFileInDatabase(updatedFile: createdDirectory)
                            let realm = createdDirectory.realm

                            let parent = realm?.object(ofType: File.self, forPrimaryKey: parentId)
                            try realm?.write {
                                createdDirectory.collaborativeFolder = dropbox.url
                                parent?.children.append(createdDirectory)
                            }
                            if let parent = createdDirectory.parent {
                                parent.signalChanges()
                                self.notifyObserversWith(file: parent)
                            }
                            completion(createdDirectory, dropbox, error)
                        } catch {
                            completion(nil, nil, error)
                        }
                    }

                }
            } else {
                completion(nil, nil, error)
            }
        }
    }

    public func createOfficeFile(parentDirectory: File, name: String, type: String, completion: @escaping (File?, Error?) -> Void) {
        let parentId = parentDirectory.id
        apiFetcher.createOfficeFile(parentDirectory: parentDirectory, name: name, type: type) { (response, error) in
            let realm = self.getRealm()
            if let file = response?.data,
                let createdFile = try? self.updateFileInDatabase(updatedFile: file, using: realm) {
                // Add file to parent
                let parent = realm.object(ofType: File.self, forPrimaryKey: parentId)
                try? realm.write {
                    parent?.children.append(createdFile)
                }
                createdFile.signalChanges()

                if let parent = createdFile.parent {
                    parent.signalChanges()
                    self.notifyObserversWith(file: parent)
                }

                completion(createdFile, error)
            } else {
                completion(nil, error)
            }
        }
    }

    public func activateShareLink(for file: File, completion: @escaping (File?, ShareLink?, Error?) -> Void) {
        apiFetcher.activateShareLinkFor(file: file) { (response, error) in
            if let link = response?.data {
                // Fix for API not returning share link activities
                let newFile = self.setFileShareLink(file: file, shareLink: link.url)?.freeze()
                completion(newFile, link, nil)
            } else {
                completion(nil, nil, error)
            }
        }
    }

    public func removeShareLink(for file: File, completion: @escaping (File?, Error?) -> Void) {
        apiFetcher.removeShareLinkFor(file: file) { (response, error) in
            if let data = response?.data {
                if data {
                    // Fix for API not returning share link activities
                    let newFile = self.setFileShareLink(file: file, shareLink: nil)?.freeze()
                    completion(newFile, nil)
                } else {
                    completion(nil, nil)
                }
            } else {
                completion(nil, error)
            }
        }
    }

    private func removeFileInDatabase(fileId: Int, cascade: Bool, withTransaction: Bool, using realm: Realm? = nil) {
        let realm = realm ?? getRealm()
        if let file = realm.object(ofType: File.self, forPrimaryKey: fileId) {
            if fileManager.fileExists(atPath: file.localContainerUrl.path) {
                try? fileManager.removeItem(at: file.localContainerUrl) // Check that it was correctly removed?
            }

            if cascade {
                for child in file.children.freeze() where !child.isInvalidated {
                    removeFileInDatabase(fileId: child.id, cascade: cascade, withTransaction: withTransaction, using: realm)
                }
            }
            if withTransaction {
                try? realm.safeWrite {
                    realm.delete(file)
                }
            } else {
                realm.delete(file)
            }
        }
    }

    private func deleteOrphanFiles(root: File..., using realm: Realm? = nil) {
        let realm = realm ?? getRealm()
        let orphanFiles = realm.objects(File.self).filter("parentLink.@count == 1").filter(NSPredicate(format: "ANY parentLink.id IN %@", root.map(\.id)))
        for orphanFile in orphanFiles {
            if fileManager.fileExists(atPath: orphanFile.localContainerUrl.path) {
                try? fileManager.removeItem(at: orphanFile.localContainerUrl) // Check that it was correctly removed?
            }
        }
        try? realm.safeWrite {
            realm.delete(orphanFiles)
        }
    }

    private func updateFileProperty(fileId: Int, using realm: Realm? = nil, _ block: (File) -> ()) {
        let realm = realm ?? getRealm()
        if let file = realm.object(ofType: File.self, forPrimaryKey: fileId) {
            try? realm.write {
                block(file)
            }
            notifyObserversWith(file: file)
        }
    }

    private func updateFileInDatabase(updatedFile: File, oldFile: File? = nil, using realm: Realm? = nil) throws -> File {
        let realm = realm ?? getRealm()
        //rename file if it was renamed in the drive
        if let oldFile = oldFile {
            try self.renameCachedFile(updatedFile: updatedFile, oldFile: oldFile)
        }

        try realm.write {
            realm.add(updatedFile, update: .modified)
        }
        return updatedFile
    }

    private func updateFileChildrenInDatabase(file: File, using realm: Realm? = nil) throws -> File {
        let realm = realm ?? getRealm()

        if let managedFile = realm.object(ofType: File.self, forPrimaryKey: file.id) {
            try realm.write {
                file.children.insert(contentsOf: managedFile.children, at: 0)
                realm.add(file.children, update: .modified)
                realm.add(file, update: .modified)
            }
            return file
        } else {
            throw DriveError.errorWithUserInfo(.fileNotFound, info: [.fileId: file.id])
        }
    }

    public func renameCachedFile(updatedFile: File, oldFile: File) throws {
        if updatedFile.name != oldFile.name && fileManager.fileExists(atPath: oldFile.localUrl.path) {
            try fileManager.moveItem(atPath: oldFile.localUrl.path, toPath: updatedFile.localUrl.path)
        }
    }

    private func keepCacheAttributesForFile(newFile: File, keepStandard: Bool, keepExtras: Bool, keepRights: Bool, using realm: Realm? = nil) {
        let realm = realm ?? getRealm()
        if let savedChild = realm.object(ofType: File.self, forPrimaryKey: newFile.id) {
            newFile.isAvailableOffline = savedChild.isAvailableOffline
            if keepStandard {
                newFile.fullyDownloaded = savedChild.fullyDownloaded
                newFile.children = savedChild.children
                newFile.responseAt = savedChild.responseAt
            }
            if keepExtras {
                newFile.canUseTag = savedChild.canUseTag
                newFile.hasVersion = savedChild.hasVersion
                newFile.nbVersion = savedChild.nbVersion
                newFile.createdBy = savedChild.createdBy
                newFile.path = savedChild.path
                newFile.sizeWithVersion = savedChild.sizeWithVersion
                newFile.users = savedChild.users.freeze()
            }
            if keepRights {
                newFile.rights = savedChild.rights
            }
        }
    }

    public func cancelAction(file: File, cancelId: String, completion: @escaping (Error?) -> Void) {
        apiFetcher.cancelAction(cancelId: cancelId) { (response, error) in
            if error == nil {
                completion(error)
            } else {
                completion(error)
            }
        }
    }
}

extension Realm {
    public func safeWrite(_ block: (() throws -> Void)) throws {
        if isInWriteTransaction {
            try block()
        } else {
            try write(block)
        }
    }
}

//MARK: - Observation
extension DriveFileManager {
    public typealias FileId = Int

    @discardableResult
    public func observeFileUpdated<T: AnyObject>(_ observer: T, fileId: FileId?, using closure: @escaping (File) -> Void)
        -> ObservationToken {
        let key = UUID()
        didUpdateFileObservers[key] = { [weak self, weak observer] updatedDirectory in
            // If the observer has been deallocated, we can
            // automatically remove the observation closure.
            guard let _ = observer else {
                self?.didUpdateFileObservers.removeValue(forKey: key)
                return
            }

            if fileId == nil || fileId == updatedDirectory.id {
                closure(updatedDirectory)
            }
        }

        return ObservationToken { [weak self] in
            self?.didUpdateFileObservers.removeValue(forKey: key)
        }
    }

    public func notifyObserversWith(file: File) {
        for observer in didUpdateFileObservers.values {
            observer(file.isFrozen ? file : file.freeze())
        }
    }
}
