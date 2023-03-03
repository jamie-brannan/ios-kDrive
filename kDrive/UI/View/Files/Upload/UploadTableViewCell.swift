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

import InfomaniakCore
import InfomaniakCoreUI
import InfomaniakDI
import kDriveCore
import kDriveResources
import RealmSwift
import UIKit

class UploadTableViewCell: InsetTableViewCell {
    // This view is reused if FileListCollectionView header
    @IBOutlet weak var cardContentView: UploadCardView!
    private var currentFileId: String?
    private var thumbnailRequest: UploadFile.ThumbnailRequest?
    private var progressObservation: NotificationToken?

    @LazyInjectService var uploadQueue: UploadQueue

    override func awakeFromNib() {
        super.awakeFromNib()
        cardContentView.retryButton?.isHidden = true
        cardContentView.iconView.isHidden = true
        cardContentView.progressView.isHidden = true
        cardContentView.iconView.isHidden = false
        cardContentView.editImage?.isHidden = true
        cardContentView.progressView.setInfomaniakStyle()
        cardContentView.iconViewHeightConstraint.constant = 24
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        cardContentView.editImage?.isHidden = true
        cardContentView.retryButton?.isHidden = true
        cardContentView.progressView.isHidden = true
        cardContentView.detailsLabel.isHidden = false
        cardContentView.iconView.image = nil
        cardContentView.iconView.contentMode = .scaleAspectFit
        cardContentView.iconView.layer.cornerRadius = 0
        cardContentView.iconView.layer.masksToBounds = false
        cardContentView.iconView.isHidden = false
        cardContentView.progressView.updateProgress(0, animated: false)
        cardContentView.iconViewHeightConstraint.constant = 24
        progressObservation?.invalidate()
    }

    deinit {
        thumbnailRequest?.cancel()
    }

    private func setStatusFor(uploadFile: UploadFile) {
        guard !uploadFile.isInvalidated else {
            return
        }
        
        if let error = uploadFile.error, error != .taskRescheduled {
            cardContentView.retryButton?.isHidden = false
            cardContentView.detailsLabel.text = KDriveResourcesStrings.Localizable.errorUpload + " (\(error.localizedDescription))"
        } else {
            cardContentView.retryButton?.isHidden = (uploadFile.maxRetryCount > 0) ? true : false // Display retry for uploads that reached automatic retry limit
            var status = KDriveResourcesStrings.Localizable.uploadInProgressPending
            if ReachabilityListener.instance.currentStatus == .offline {
                status = KDriveResourcesStrings.Localizable.uploadNetworkErrorDescription
            } else if UserDefaults.shared.isWifiOnly && ReachabilityListener.instance.currentStatus != .wifi {
                status = KDriveResourcesStrings.Localizable.uploadNetworkErrorWifiRequired
            }
            if uploadFile.size > 0 {
                cardContentView.detailsLabel.text = uploadFile.formattedSize + " • " + status
            } else {
                cardContentView.detailsLabel.text = status
            }
        }
    }

    private func addThumbnail(image: UIImage) {
        DispatchQueue.main.async {
            self.cardContentView.iconView.layer.cornerRadius = UIConstants.imageCornerRadius
            self.cardContentView.iconView.contentMode = .scaleAspectFill
            self.cardContentView.iconView.layer.masksToBounds = true
            self.cardContentView.iconViewHeightConstraint.constant = 38
            self.cardContentView.iconView.image = image
        }
    }
    
    func configureWith(uploadFile: UploadFile, progress: CGFloat?) {
        guard !uploadFile.isInvalidated else {
            return
        }
        
        // Set initial progress value
        if let progress = progress {
            self.updateProgress(fileId: uploadFile.id, progress: progress, animated: true)
        }
        
        // observe the progres
        let observationClosure: (ObjectChange<UploadFile>) -> Void = { [weak self] change in
               guard let self else {
                   return
               }

               switch change {
               case .change(let newFile, _):
                   guard let progress = newFile.progress,
                         (newFile.error == nil || newFile.error == DriveError.taskRescheduled) == true else {
                       return
                   }

                   self.updateProgress(fileId: newFile.id, progress: progress, animated: false)
               case .error(_), .deleted:
                   break
               }
        }
        self.progressObservation = uploadFile.observe(keyPaths:  ["progress"], observationClosure)
        
        currentFileId = uploadFile.id
        cardContentView.titleLabel.text = uploadFile.name
        setStatusFor(uploadFile: uploadFile)

        cardContentView.iconView.image = uploadFile.convertedType.icon
        thumbnailRequest = uploadFile.getThumbnail { [weak self] image in
            self?.addThumbnail(image: image)
        }

        cardContentView.cancelButtonPressedHandler = {
            guard !uploadFile.isInvalidated else {
                return
            }
            
            let realm = DriveFileManager.constants.uploadsRealm
            if let file = realm.object(ofType: UploadFile.self, forPrimaryKey: uploadFile.id), !file.isInvalidated {
                self.uploadQueue.cancel(file)
            }
        }
        cardContentView.retryButtonPressedHandler = { [weak self] in
            guard let self, !uploadFile.isInvalidated else {
                return
            }
            
            self.cardContentView.retryButton?.isHidden = true
            let realm = DriveFileManager.constants.uploadsRealm
            if let file = realm.object(ofType: UploadFile.self, forPrimaryKey: uploadFile.id), !file.isInvalidated {
                self.uploadQueue.retry(file)
            }
        }
    }

    func configureWith(importedFile: ImportedFile) {
        cardContentView.cancelButton?.isHidden = true
        cardContentView.retryButton?.isHidden = true
        cardContentView.editImage?.isHidden = false

        cardContentView.editImage?.image = KDriveResourcesAsset.edit.image
        cardContentView.iconView.image = ConvertedType.fromUTI(importedFile.uti).icon
        cardContentView.titleLabel.text = importedFile.name
        cardContentView.detailsLabel.isHidden = true
        let request = importedFile.getThumbnail { [weak self] image in
            self?.addThumbnail(image: image)
        }
        thumbnailRequest = .qlThumbnailRequest(request)
    }

    func updateProgress(fileId: String, progress: CGFloat, animated: Bool = true) {
        if let currentFileId = currentFileId, fileId == currentFileId {
            cardContentView.iconView.isHidden = true
            cardContentView.progressView.isHidden = false
            cardContentView.progressView.updateProgress(progress, animated: animated)

            var status = KDriveResourcesStrings.Localizable.uploadInProgressTitle
            if ReachabilityListener.instance.currentStatus == .offline {
                status += " • " + KDriveResourcesStrings.Localizable.uploadNetworkErrorDescription
            } else if UserDefaults.shared.isWifiOnly && ReachabilityListener.instance.currentStatus != .wifi {
                status += " • " + KDriveResourcesStrings.Localizable.uploadNetworkErrorWifiRequired
            }
            cardContentView.detailsLabel.text = status
        }
    }
}
