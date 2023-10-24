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
import InfomaniakDI
import InfomaniakLogin
import kDriveCore
import UIKit

final class ActionNavigationController: TitleSizeAdjustingNavigationController {
    /// Making sure the DI is registered at a very early stage of the app launch.
    private let dependencyInjectionHook = EarlyDIHook()

    @LazyInjectService var accountManager: AccountManageable

    override func viewDidLoad() {
        super.viewDidLoad()
        // Modify sheet size on iPadOS, property is ignored on iOS
        preferredContentSize = CGSize(width: 540, height: 620)
        Logging.initLogging()

        let saveFileViewController = SaveFileViewController.instantiate(driveFileManager: accountManager.currentDriveFileManager)
        let itemProviders = fetchAttachments()
        guard !itemProviders.isEmpty else {
            // No items found
            dismiss(animated: true)
            return
        }

        saveFileViewController.itemProviders = itemProviders
        viewControllers = [saveFileViewController]
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard let extensionContext else {
            return
        }
        extensionContext.completeRequest(returningItems: extensionContext.inputItems, completionHandler: nil)
    }
}
