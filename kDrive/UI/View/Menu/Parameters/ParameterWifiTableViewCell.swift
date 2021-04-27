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

class ParameterWifiTableViewCell: InsetTableViewCell {

    @IBOutlet weak var wifiSwitch: UISwitch!
    @IBOutlet weak var detailsLabel: UILabel!
    var switchHandler: ((UISwitch) -> Void)?

    @IBAction func wifiOnlySwitchChanged(_ sender: UISwitch) {
        switchHandler?(sender)
    }

    override func setSelected(_ selected: Bool, animated: Bool) { }
}
