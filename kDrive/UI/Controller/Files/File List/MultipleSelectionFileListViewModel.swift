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

import CocoaLumberjackSwift
import Foundation
import kDriveCore
import kDriveResources

enum MultipleSelectionBarButtonType {
    case selectAll
    case deselectAll
    case loading
    case cancel
}

struct MultipleSelectionAction: Equatable {
    let id: Int
    let name: String
    let icon: KDriveResourcesImages
    var enabled = true

    static func == (lhs: MultipleSelectionAction, rhs: MultipleSelectionAction) -> Bool {
        return lhs.id == rhs.id
    }

    static let move = MultipleSelectionAction(id: 0, name: KDriveResourcesStrings.Localizable.buttonMove, icon: KDriveResourcesAsset.folderSelect)
    static let delete = MultipleSelectionAction(id: 1, name: KDriveResourcesStrings.Localizable.buttonMove, icon: KDriveResourcesAsset.delete)
    static let more = MultipleSelectionAction(id: 2, name: KDriveResourcesStrings.Localizable.buttonMove, icon: KDriveResourcesAsset.menu)
}

@MainActor
class MultipleSelectionFileListViewModel {
    /// itemIndex
    typealias ItemSelectedCallback = (Int) -> Void
    /// driveFileManager, startDirectory, disabledDirectories
    typealias SelectMoveDestinationCallback = (DriveFileManager, File, [File]) -> Void
    /// deleteMessage
    typealias DeleteConfirmationCallback = (NSMutableAttributedString) -> Void
    /// selectedFiles
    typealias MoreButtonPressedCallback = ([File]) -> Void

    @Published var isMultipleSelectionEnabled: Bool {
        didSet {
            if isMultipleSelectionEnabled {
                leftBarButtons = [.cancel]
                if configuration.selectAllSupported {
                    rightBarButtons = [.selectAll]
                }
            } else {
                leftBarButtons = nil
                rightBarButtons = nil
                selectedItems.removeAll()
                selectedCount = 0
                isSelectAllModeEnabled = false
            }
        }
    }

    @Published var selectedCount: Int
    @Published var leftBarButtons: [MultipleSelectionBarButtonType]?
    @Published var rightBarButtons: [MultipleSelectionBarButtonType]?
    @Published var multipleSelectionActions: [MultipleSelectionAction]

    var onItemSelected: ItemSelectedCallback?
    var onSelectAll: (() -> Void)?
    var onDeselectAll: (() -> Void)?
    var onSelectMoveDestination: SelectMoveDestinationCallback?
    var onDeleteConfirmation: DeleteConfirmationCallback?
    var onMoreButtonPressed: MoreButtonPressedCallback?

    private(set) var selectedItems = Set<File>()
    var isSelectAllModeEnabled = false

    private var driveFileManager: DriveFileManager
    private var currentDirectory: File
    private var configuration: FileListViewController.Configuration

    init(configuration: FileListViewController.Configuration, driveFileManager: DriveFileManager, currentDirectory: File) {
        isMultipleSelectionEnabled = false
        selectedCount = 0
        multipleSelectionActions = [.move, .delete, .more]
        self.driveFileManager = driveFileManager
        self.currentDirectory = currentDirectory
        self.configuration = configuration
    }

    func barButtonPressed(type: MultipleSelectionBarButtonType) {
        switch type {
        case .selectAll:
            selectAll()
        case .deselectAll:
            deselectAll()
        case .loading:
            break
        case .cancel:
            isMultipleSelectionEnabled = false
        }
    }

    func actionButtonPressed(action: MultipleSelectionAction) {
        switch action {
        case .move:
            onSelectMoveDestination?(driveFileManager, currentDirectory, [selectedItems.first?.parent ?? driveFileManager.getRootFile()])
        case .delete:
            var message: NSMutableAttributedString
            if selectedCount == 1,
               let firstItem = selectedItems.first {
                message = NSMutableAttributedString(string: KDriveResourcesStrings.Localizable.modalMoveTrashDescription(selectedItems.first!.name), boldText: firstItem.name)
            } else {
                message = NSMutableAttributedString(string: KDriveResourcesStrings.Localizable.modalMoveTrashDescriptionPlural(selectedCount))
            }
            onDeleteConfirmation?(message)
        case .more:
            onMoreButtonPressed?(Array(selectedItems))
        default:
            break
        }
    }

    func selectAll() {
        selectedItems.removeAll()
        isSelectAllModeEnabled = true
        rightBarButtons = [.loading]
        onSelectAll?()
        let frozenDirectory = currentDirectory.freeze()
        Task {
            do {
                let directoryCount = try await driveFileManager.apiFetcher.count(of: frozenDirectory)
                selectedCount = directoryCount.count
                rightBarButtons = [.deselectAll]
            } catch {
                deselectAll()
            }
        }
    }

    func deselectAll() {
        selectedCount = 0
        selectedItems.removeAll()
        isSelectAllModeEnabled = false
        rightBarButtons = [.selectAll]
        onDeselectAll?()
    }

    func didSelectFile(_ file: File, at index: Int) {
        selectedItems.insert(file)
        selectedCount = selectedItems.count
        onItemSelected?(index)
    }

    func didDeselectFile(_ file: File, at index: Int) {
        if isSelectAllModeEnabled {
            deselectAll()
            didSelectFile(file, at: index)
        } else {
            selectedItems.remove(file)
            selectedCount = selectedItems.count
        }
    }

    func moveSelectedItems(to destinationDirectory: File) {
        if isSelectAllModeEnabled {
            bulkMoveAll(destinationId: destinationDirectory.id)
        } else if selectedCount > Constants.bulkActionThreshold {
            bulkMoveFiles(Array(selectedItems), destinationId: destinationDirectory.id)
        } else {
            Task(priority: .userInitiated) {
                let group = DispatchGroup()
                var success = true
                for file in selectedItems {
                    group.enter()
                    driveFileManager.moveFile(file: file, newParent: destinationDirectory) { _, _, error in
                        if let error = error {
                            success = false
                            DDLogError("Error while moving file: \(error)")
                        }
                        group.leave()
                    }
                }
                group.notify(queue: DispatchQueue.main) { [weak self] in
                    guard let self = self else { return }
                    // TODO: move snackbar out of viewmodel
                    let message = success ? KDriveResourcesStrings.Localizable.fileListMoveFileConfirmationSnackbar(self.selectedItems.count, destinationDirectory.name) : KDriveResourcesStrings.Localizable.errorMove
                    UIConstants.showSnackBar(message: message)
                    self.isMultipleSelectionEnabled = false
                }
            }
        }
    }

    func deleteSelectedItems() {
        if isSelectAllModeEnabled {
            bulkDeleteAll()
        } else if selectedCount > Constants.bulkActionThreshold {
            bulkDeleteFiles(Array(selectedItems))
        } else {
            let group = DispatchGroup()
            group.enter()
            Task(priority: .userInitiated) {
                var success = true
                for file in selectedItems {
                    group.enter()
                    driveFileManager.deleteFile(file: file) { _, error in
                        if let error = error {
                            success = false
                            DDLogError("Error while deleting file: \(error)")
                        }
                        group.leave()
                    }
                }
                group.leave()

                group.notify(queue: DispatchQueue.main) { [weak self] in
                    guard let self = self else { return }
                    let message: String
                    if success {
                        if self.selectedCount == 1,
                           let firstItem = self.selectedItems.first {
                            message = KDriveResourcesStrings.Localizable.snackbarMoveTrashConfirmation(firstItem.name)
                        } else {
                            message = KDriveResourcesStrings.Localizable.snackbarMoveTrashConfirmationPlural(self.selectedCount)
                        }
                    } else {
                        message = KDriveResourcesStrings.Localizable.errorMove
                    }
                    UIConstants.showSnackBar(message: message)
                    self.isMultipleSelectionEnabled = false
                }
            }
            group.wait()
        }
    }

    // MARK: - Bulk actions

    private func bulkMoveFiles(_ files: [File], destinationId: Int) {
        let action = BulkAction(action: .move, fileIds: files.map(\.id), destinationDirectoryId: destinationId)
        driveFileManager.apiFetcher.bulkAction(driveId: driveFileManager.drive.id, action: action) { response, error in
            self.bulkObservation(action: .move, response: response, error: error)
        }
    }

    private func bulkMoveAll(destinationId: Int) {
        let action = BulkAction(action: .move, parentId: currentDirectory.id, destinationDirectoryId: destinationId)
        driveFileManager.apiFetcher.bulkAction(driveId: driveFileManager.drive.id, action: action) { response, error in
            self.bulkObservation(action: .move, response: response, error: error)
        }
    }

    private func bulkDeleteFiles(_ files: [File]) {
        let action = BulkAction(action: .trash, fileIds: files.map(\.id))
        driveFileManager.apiFetcher.bulkAction(driveId: driveFileManager.drive.id, action: action) { response, error in
            self.bulkObservation(action: .trash, response: response, error: error)
        }
    }

    private func bulkDeleteAll() {
        let action = BulkAction(action: .trash, parentId: currentDirectory.id)
        driveFileManager.apiFetcher.bulkAction(driveId: driveFileManager.drive.id, action: action) { response, error in
            self.bulkObservation(action: .trash, response: response, error: error)
        }
    }

    public func bulkObservation(action: BulkActionType, response: ApiResponse<CancelableResponse>?, error: Error?) {
        isMultipleSelectionEnabled = false
        let cancelId = response?.data?.id
        if let error = error {
            DDLogError("Error while deleting file: \(error)")
        } else {
            let message: String
            switch action {
            case .trash:
                message = KDriveResourcesStrings.Localizable.fileListDeletionStartedSnackbar
            case .move:
                message = KDriveResourcesStrings.Localizable.fileListMoveStartedSnackbar
            case .copy:
                message = KDriveResourcesStrings.Localizable.fileListCopyStartedSnackbar
            }
            let progressSnack = UIConstants.showSnackBar(message: message, duration: .infinite, action: IKSnackBar.Action(title: KDriveResourcesStrings.Localizable.buttonCancel) {
                if let cancelId = cancelId {
                    self.driveFileManager.cancelAction(cancelId: cancelId) { error in
                        if let error = error {
                            DDLogError("Cancel error: \(error)")
                        }
                    }
                }
            })
            AccountManager.instance.mqService.observeActionProgress(self, actionId: cancelId) { actionProgress in
                DispatchQueue.main.async { [weak self] in
                    switch actionProgress.progress.message {
                    case .starting:
                        break
                    case .processing:
                        switch action {
                        case .trash:
                            progressSnack?.message = KDriveResourcesStrings.Localizable.fileListDeletionInProgressSnackbar(actionProgress.progress.total - actionProgress.progress.todo, actionProgress.progress.total)
                        case .move:
                            progressSnack?.message = KDriveResourcesStrings.Localizable.fileListMoveInProgressSnackbar(actionProgress.progress.total - actionProgress.progress.todo, actionProgress.progress.total)
                        case .copy:
                            progressSnack?.message = KDriveResourcesStrings.Localizable.fileListCopyInProgressSnackbar(actionProgress.progress.total - actionProgress.progress.todo, actionProgress.progress.total)
                        }
                        self?.notifyObserversForCurrentDirectory()
                    case .done:
                        switch action {
                        case .trash:
                            progressSnack?.message = KDriveResourcesStrings.Localizable.fileListDeletionDoneSnackbar
                        case .move:
                            progressSnack?.message = KDriveResourcesStrings.Localizable.fileListMoveDoneSnackbar
                        case .copy:
                            progressSnack?.message = KDriveResourcesStrings.Localizable.fileListCopyDoneSnackbar
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            progressSnack?.dismiss()
                        }
                        self?.notifyObserversForCurrentDirectory()
                    case .canceled:
                        let message: String
                        switch action {
                        case .trash:
                            message = KDriveResourcesStrings.Localizable.allTrashActionCancelled
                        case .move:
                            message = KDriveResourcesStrings.Localizable.allFileMoveCancelled
                        case .copy:
                            message = KDriveResourcesStrings.Localizable.allFileDuplicateCancelled
                        }
                        UIConstants.showSnackBar(message: message)
                        self?.notifyObserversForCurrentDirectory()
                    }
                }
            }
        }
    }

    private func notifyObserversForCurrentDirectory() {
        driveFileManager.notifyObserversWith(file: currentDirectory)
    }
}
