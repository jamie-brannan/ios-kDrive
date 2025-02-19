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

import InfomaniakCoreUI
import kDriveCore
import kDriveResources
import RealmSwift
import UIKit

protocol SelectFolderDelegate: AnyObject {
    func didSelectFolder(_ folder: File)
}

class SelectFolderViewModel: ConcreteFileListViewModel {
    required init(driveFileManager: DriveFileManager, currentDirectory: File?) {
        let currentDirectory = currentDirectory ?? driveFileManager.getCachedRootFile()
        let configuration = Configuration(showUploadingFiles: false,
                                          isMultipleSelectionEnabled: false,
                                          rootTitle: KDriveResourcesStrings.Localizable.selectFolderTitle,
                                          emptyViewType: .emptyFolderSelectFolder,
                                          leftBarButtons: currentDirectory.id == DriveFileManager.constants
                                              .rootID ? [.cancel] : nil,
                                          rightBarButtons: currentDirectory.capabilities.canCreateDirectory ? [.addFolder] : nil,
                                          matomoViewPath: [MatomoUtils.Views.save.displayName, "SelectFolder"])

        super.init(configuration: configuration, driveFileManager: driveFileManager, currentDirectory: currentDirectory)
    }
}

class SelectFolderViewController: FileListViewController {
    override class var storyboard: UIStoryboard { Storyboard.saveFile }
    override class var storyboardIdentifier: String { "SelectFolderViewController" }

    @IBOutlet weak var selectFolderButton: UIButton!

    var disabledDirectoriesSelection = [Int]()
    var fileToMove: Int?
    weak var delegate: SelectFolderDelegate?
    var selectHandler: ((File) -> Void)?

    override func viewDidLoad() {
        // Set configuration
        super.viewDidLoad()

        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: UIConstants.listFloatingButtonPaddingBottom, right: 0)
        setUpDirectory()
    }

    private func setUpDirectory() {
        selectFolderButton.isEnabled = !disabledDirectoriesSelection
            .contains(viewModel.currentDirectory.id) &&
            (viewModel.currentDirectory.capabilities.canMoveInto || viewModel.currentDirectory.capabilities.canCreateFile)
    }

    static func instantiateInNavigationController(driveFileManager: DriveFileManager,
                                                  startDirectory: File? = nil, fileToMove: Int? = nil,
                                                  disabledDirectoriesIdsSelection: [Int],
                                                  delegate: SelectFolderDelegate? = nil,
                                                  selectHandler: ((File) -> Void)? = nil)
        -> TitleSizeAdjustingNavigationController {
        var viewControllers = [SelectFolderViewController]()
        if startDirectory == nil || startDirectory?.isRoot == true {
            let selectFolderViewController = instantiate(viewModel: SelectFolderViewModel(
                driveFileManager: driveFileManager,
                currentDirectory: nil
            ))
            selectFolderViewController.disabledDirectoriesSelection = disabledDirectoriesIdsSelection
            selectFolderViewController.fileToMove = fileToMove
            selectFolderViewController.delegate = delegate
            selectFolderViewController.selectHandler = selectHandler
            selectFolderViewController.navigationItem.hideBackButtonText()
            viewControllers.append(selectFolderViewController)
        } else {
            var directory = startDirectory
            while directory != nil {
                let selectFolderViewController = instantiate(viewModel: SelectFolderViewModel(
                    driveFileManager: driveFileManager,
                    currentDirectory: directory
                ))
                selectFolderViewController.disabledDirectoriesSelection = disabledDirectoriesIdsSelection
                selectFolderViewController.fileToMove = fileToMove
                selectFolderViewController.delegate = delegate
                selectFolderViewController.selectHandler = selectHandler
                selectFolderViewController.navigationItem.hideBackButtonText()
                viewControllers.append(selectFolderViewController)
                directory = directory?.parent
            }
        }
        let navigationController = TitleSizeAdjustingNavigationController()
        navigationController.setViewControllers(viewControllers.reversed(), animated: false)
        navigationController.navigationBar.prefersLargeTitles = true
        return navigationController
    }

    static func instantiateInNavigationController(driveFileManager: DriveFileManager,
                                                  startDirectory: File? = nil, fileToMove: Int? = nil,
                                                  disabledDirectoriesSelection: [File] = [],
                                                  delegate: SelectFolderDelegate? = nil,
                                                  selectHandler: ((File) -> Void)? = nil)
        -> TitleSizeAdjustingNavigationController {
        let disabledDirectoriesIdsSelection = disabledDirectoriesSelection.map(\.id)
        return instantiateInNavigationController(
            driveFileManager: driveFileManager,
            startDirectory: startDirectory,
            fileToMove: fileToMove,
            disabledDirectoriesIdsSelection: disabledDirectoriesIdsSelection,
            delegate: delegate,
            selectHandler: selectHandler
        )
    }

    // MARK: - Actions

    override func barButtonPressed(_ sender: FileListBarButton) {
        if sender.type == .cancel {
            dismiss(animated: true)
        } else if sender.type == .addFolder {
            MatomoUtils.track(eventWithCategory: .newElement, name: "newFolderOnTheFly")
            let newFolderViewController = NewFolderTypeTableViewController.instantiateInNavigationController(
                parentDirectory: viewModel.currentDirectory,
                driveFileManager: viewModel.driveFileManager
            )
            navigationController?.present(newFolderViewController, animated: true)
        } else {
            super.barButtonPressed(sender)
        }
    }

    @IBAction func selectButtonPressed(_ sender: UIButton) {
        let frozenSelectedDirectory = viewModel.currentDirectory.freezeIfNeeded()
        delegate?.didSelectFolder(frozenSelectedDirectory)
        selectHandler?(frozenSelectedDirectory)
        // We are only selecting files we can dismiss
        if navigationController?.viewControllers.first is SelectFolderViewController {
            navigationController?.dismiss(animated: true)
        } else {
            // We are creating file, go back to file name
            navigationController?.popToRootViewController(animated: true)
        }
    }

    // MARK: - Collection view data source

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let file = viewModel.getFile(at: indexPath)!
        let cell = super.collectionView(collectionView, cellForItemAt: indexPath) as! FileCollectionViewCell
        cell.setEnabled(file.isDirectory && file.id != fileToMove)
        cell.moreButton.isHidden = true
        return cell
    }

    // MARK: - Collection view delegate

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let selectedFile = viewModel.getFile(at: indexPath)!
        if selectedFile.isDirectory {
            let nextVC = SelectFolderViewController.instantiate(viewModel: SelectFolderViewModel(
                driveFileManager: viewModel.driveFileManager,
                currentDirectory: selectedFile
            ))
            nextVC.disabledDirectoriesSelection = disabledDirectoriesSelection
            nextVC.fileToMove = fileToMove
            nextVC.delegate = delegate
            nextVC.selectHandler = selectHandler
            navigationController?.pushViewController(nextVC, animated: true)
        }
    }

    // MARK: - State restoration

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)

        coder.encode(disabledDirectoriesSelection, forKey: "DisabledDirectories")
    }

    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)

        disabledDirectoriesSelection = coder.decodeObject(forKey: "DisabledDirectories") as? [Int] ?? []
        setUpDirectory()
    }
}
