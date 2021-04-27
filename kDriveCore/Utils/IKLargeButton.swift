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

@IBDesignable public class IKLargeButton: UIButton {

    /// Toggle shadow elevation.
    @IBInspectable public var elevated: Bool = false {
        didSet { setElevation() }
    }

    /// Set elevation value.
    @IBInspectable public var elevation: Int = 1 {
        didSet { setElevation() }
    }

    public override var isEnabled: Bool {
        didSet { setEnabled() }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUpButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpButton()
    }

    public override func prepareForInterfaceBuilder() {
        super.prepareForInterfaceBuilder()
        setUpButton()
    }

    func setUpButton() {
        layer.cornerRadius = 10

        // Set text color
        setTitleColor(.white, for: .normal)
        if #available(iOS 13.0, *) {
            UITraitCollection.current.userInterfaceStyle == .dark ? setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .disabled) : setTitleColor(UIColor.black.withAlphaComponent(0.37), for: .disabled)
        } else {
            backgroundColor = isEnabled ? KDriveCoreAsset.infomaniakColor.color : UIColor.black.withAlphaComponent(0.12)
        }
        setBackgroundColor()
        setElevation()
    }

    func setBackgroundColor() {
        if #available(iOS 13.0, *) {
            backgroundColor = isEnabled ? KDriveCoreAsset.infomaniakColor.color : UITraitCollection.current.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : UIColor.black.withAlphaComponent(0.12)
        } else {
            backgroundColor = isEnabled ? KDriveCoreAsset.infomaniakColor.color : UIColor.black.withAlphaComponent(0.12)
        }
    }

    func setElevation() {
        if elevated && isEnabled {
            addShadow(elevation: Double(elevation))
        } else {
            layer.shadowColor = nil
            layer.shadowOpacity = 0.0
        }
    }

    func setEnabled() {
        setElevation()
        setBackgroundColor()
    }
}
