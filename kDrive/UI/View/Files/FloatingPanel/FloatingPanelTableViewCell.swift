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
    @IBOutlet weak var progressView: RPCircularProgress!
    @IBOutlet weak var disabledView: UIView!

    private var observationToken: ObservationToken?

    override func awakeFromNib() {
        super.awakeFromNib()

        progressView.isHidden = true
        progressView.setInfomaniakStyle()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        observationToken?.cancel()
        observationToken = nil
        contentInsetView.backgroundColor = KDriveAsset.backgroundCardViewColor.color
        accessoryImageView.isHidden = false
        progressView.isHidden = true
        progressView.updateProgress(0, animated: false)
    }

    func setProgress(_ progress: CGFloat? = -1) {
        if let downloadProgress = progress, downloadProgress < 1 {
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

    func observeProgress(_ showProgress: Bool, archiveId: String) {
        observationToken?.cancel()
        setProgress(showProgress ? -1 : nil)
        if showProgress {
            observationToken = DownloadQueue.instance.observeArchiveDownloadProgress(self, archiveId: archiveId) { _, progress in
                DispatchQueue.main.async { [weak self] in
                    self?.setProgress(CGFloat(progress))
                }
            }
        }
    }
}
