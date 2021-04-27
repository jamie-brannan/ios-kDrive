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

import UIKit
import InfomaniakCore
import kDriveCore
import MaterialOutlinedTextField

protocol NewFolderTextFieldDelegate: AnyObject {
    func textFieldUpdated(content: String)
}

class NewFolderHeaderTableViewCell: InsetTableViewCell, UITextFieldDelegate {

    @IBOutlet weak var titleTextField: MaterialOutlinedTextField!
    weak var delegate: NewFolderTextFieldDelegate?

    override func awakeFromNib() {
        super.awakeFromNib()

        titleTextField.setInfomaniakColors()
        titleTextField.backgroundColor = KDriveAsset.backgroundCardViewColor.color
        titleTextField.delegate = self
        titleTextField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.endEditing(true)
        return true
    }

    @objc func textFieldDidChange() {
        delegate?.textFieldUpdated(content: titleTextField.text ?? "")
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    }

    func configureWith(folderType: FolderType) {
        if folderType == .folder {
            titleLabel.text = KDriveStrings.Localizable.createFolderTitle
            accessoryImageView.image = KDriveAsset.folderFilled.image
            titleTextField.setHint(KDriveStrings.Localizable.hintInputDirName)
        } else if folderType == .commonFolder {
            titleLabel.text = KDriveStrings.Localizable.createCommonFolderTitle
            accessoryImageView.image = KDriveAsset.folderCommonDocuments.image
            titleTextField.setHint(KDriveStrings.Localizable.hintInputDirName)
        } else {
            titleLabel.text = KDriveStrings.Localizable.createDropBoxTitle
            accessoryImageView.image = KDriveAsset.folderDropBox.image
            titleTextField.setHint(KDriveStrings.Localizable.createDropBoxHint)
        }
    }

}
