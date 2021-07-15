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
import kDriveCore
import UIKit

class FloatingPanelTableViewCell: InsetTableViewCell {
    @IBOutlet weak var offlineSwitch: UISwitch!
    @IBOutlet weak var progressView: RPCircularProgress!
    @IBOutlet weak var disabledView: UIView!
    private var observationToken: ObservationToken?

    override func awakeFromNib() {
        super.awakeFromNib()
        offlineSwitch.isHidden = true
        progressView.isHidden = true
        progressView.trackTintColor = KDriveAsset.secondaryTextColor.color.withAlphaComponent(0.2)
        progressView.progressTintColor = KDriveAsset.infomaniakColor.color
        progressView.thicknessRatio = 0.15
        progressView.indeterminateProgress = 0.75
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observationToken?.cancel()
        observationToken = nil
        offlineSwitch.setOn(true, animated: false)
        contentInsetView.backgroundColor = KDriveAsset.backgroundCardViewColor.color
        accessoryImageView.isHidden = false
        offlineSwitch.isHidden = true
        progressView.isHidden = true
        progressView.updateProgress(0, animated: false)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            disabledView.isHidden = true
            disabledView.superview?.sendSubviewToBack(disabledView)
            isUserInteractionEnabled = true
        } else {
            disabledView.backgroundColor = KDriveAsset.backgroundCardViewColor.color
            disabledView.isHidden = false
            disabledView.superview?.bringSubviewToFront(disabledView)
            isUserInteractionEnabled = false
        }
    }

    func setProgress(_ progress: CGFloat? = -1) {
        if let downloadProgress = progress {
            accessoryImageView.isHidden = true
            progressView.isHidden = false
            if downloadProgress < 0 {
                progressView.enableIndeterminate()
            } else {
                progressView.enableIndeterminate(false)
                progressView.updateProgress(downloadProgress)
            }
        } else {
            accessoryImageView.isHidden = false
            progressView.isHidden = true
        }
    }

    func configureAvailableOffline(with file: File, progress: CGFloat?) {
        observationToken?.cancel()
        offlineSwitch.isHidden = false
        if offlineSwitch.isOn != file.isAvailableOffline {
            offlineSwitch.setOn(file.isAvailableOffline, animated: true)
        }

        if file.isAvailableOffline && FileManager.default.fileExists(atPath: file.localUrl.path) {
            accessoryImageView.isHidden = false
            progressView.isHidden = true

            accessoryImageView.image = KDriveAsset.check.image
            accessoryImageView.tintColor = KDriveAsset.greenColor.color
        } else if file.isAvailableOffline {
            setProgress(progress)
        } else {
            accessoryImageView.isHidden = false
            progressView.isHidden = true

            accessoryImageView.image = KDriveAsset.availableOffline.image
            accessoryImageView.tintColor = KDriveAsset.iconColor.color
        }
        if progress != nil {
            observationToken = DownloadQueue.instance.observeFileDownloadProgress(self, fileId: file.id) { _, progress in
                DispatchQueue.main.async { [weak self] in
                    guard self?.observationToken != nil else { return }
                    self?.setProgress(CGFloat(progress))
                    if progress >= 1 {
                        self?.configureAvailableOffline(with: file, progress: nil)
                    }
                }
            }
        }
    }

    func configureDownload(with file: File, progress: CGFloat?) {
        observationToken?.cancel()
        if progress == nil {
            accessoryImageView.isHidden = false
            progressView.isHidden = true

            accessoryImageView.image = KDriveAsset.download.image
            accessoryImageView.tintColor = KDriveAsset.iconColor.color
        } else {
            observationToken = DownloadQueue.instance.observeFileDownloadProgress(self, fileId: file.id) { _, progress in
                DispatchQueue.main.async { [weak self] in
                    guard self?.observationToken != nil else { return }
                    self?.setProgress(CGFloat(progress))
                    if progress >= 1 {
                        self?.configureDownload(with: file, progress: nil)
                    }
                }
            }
        }
    }
}
