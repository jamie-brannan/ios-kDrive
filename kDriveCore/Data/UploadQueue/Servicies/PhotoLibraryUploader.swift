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
import InfomaniakCore
import InfomaniakDI
import Photos
import RealmSwift
import Sentry

public final class PhotoLibraryUploader {
    @LazyInjectService var uploadQueue: UploadQueue

    /// Threshold value to trigger cleaning of photo roll if enabled
    static let removeAssetsCountThreshold = 10

    /// Predicate to quickly narrow down on uploaded assets
    static let uploadedAssetPredicate = NSPredicate(format: "rawType = %@ AND uploadDate != nil", "phAsset")

    var _settings: PhotoSyncSettings?
    public var settings: PhotoSyncSettings? {
        _settings
    }

    public var isSyncEnabled: Bool {
        return settings != nil
    }

    public init() {
        if let settings = DriveFileManager.constants.uploadsRealm.objects(PhotoSyncSettings.self).first {
            _settings = PhotoSyncSettings(value: settings)
        }
    }

    func getUrl(for asset: PHAsset) async -> URL? {
        return await asset.getUrl(preferJPEGFormat: settings?.photoFormat == .jpg)
    }
}
