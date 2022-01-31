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

import kDriveCore
import kDriveResources
import RealmSwift
import UIKit

class OfflineFilesViewModel: ManagedFileListViewModel {
    init(configuration: Configuration, driveFileManager: DriveFileManager) {
        super.init(configuration: configuration, driveFileManager: driveFileManager, currentDirectory: nil)
        self.files = AnyRealmCollection(driveFileManager.getRealm().objects(File.self).filter(NSPredicate(format: "isAvailableOffline = true")))
    }

    override func loadFiles(page: Int = 1, forceRefresh: Bool = false) {}

    override func loadActivities() {}
}

class OfflineViewController: FileListViewController {
    override class var storyboard: UIStoryboard { Storyboard.menu }
    override class var storyboardIdentifier: String { "OfflineViewController" }

    override func getViewModel() -> FileListViewModel {
        let configuration = FileListViewModel.Configuration(normalFolderHierarchy: false, showUploadingFiles: false, isRefreshControlEnabled: false, selectAllSupported: false, rootTitle: KDriveResourcesStrings.Localizable.offlineFileTitle, emptyViewType: .noOffline)
        return OfflineFilesViewModel(configuration: configuration, driveFileManager: driveFileManager)
    }
}
