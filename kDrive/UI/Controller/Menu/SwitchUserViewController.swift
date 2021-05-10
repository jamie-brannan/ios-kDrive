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
import InfomaniakLogin
import kDriveCore

class SwitchUserViewController: UIViewController {

    @IBOutlet weak var tableView: UITableView!
    let accountManager = AccountManager.instance

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(cellView: UserAccountTableViewCell.self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setTransparentStandardAppearanceNavigationBar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setDefaultStandardAppearanceNavigationBar()
    }

    @IBAction func buttonAddUserClicked(_ sender: UIButton) {
        let nextViewController = OnboardingViewController.instantiate()
        nextViewController.addUser = true
        present(nextViewController, animated: true)
    }

    class func instantiate() -> SwitchUserViewController {
        return UIStoryboard(name: "Menu", bundle: nil).instantiateViewController(withIdentifier: "SwitchUserViewController") as! SwitchUserViewController
    }

    class func instantiateInNavigationController() -> UINavigationController {
        let switchUserViewController = instantiate()
        return UINavigationController(rootViewController: switchUserViewController)
    }

}
// MARK: - UITableViewDelegate
extension SwitchUserViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let account = accountManager.accounts[indexPath.row]

        if !account.isConnected {
            // Ask to reconnect
            InfomaniakLogin.webviewLoginFrom(viewController: self, delegate: self)
            return
        }

        let drives = DriveInfosManager.instance.getDrives(for: account.userId)
        if drives.count == 1 && drives[0].maintenance {
            let driveErrorVC = DriveErrorViewController.instantiate()
            driveErrorVC.driveErrorViewType = .maintenance
            driveErrorVC.driveName = drives[0].name
            self.present(driveErrorVC, animated: true, completion: nil)
        } else {
            AccountManager.instance.switchAccount(newAccount: account)
            (UIApplication.shared.delegate as? AppDelegate)?.refreshCacheData(preload: true, isSwitching: true)
            self.navigationController?.popViewController(animated: true)
        }
    }

}
// MARK: - UITableViewDataSource
extension SwitchUserViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return accountManager.accounts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let account = accountManager.accounts[indexPath.row]
        let cell = tableView.dequeueReusableCell(type: UserAccountTableViewCell.self, for: indexPath)
        cell.initWithPositionAndShadow(isFirst: true, isLast: true)
        cell.titleLabel.text = account.user.displayName
        cell.userEmailLabel.text = account.user.email
        cell.logoImage.image = KDriveAsset.placeholderAvatar.image

        account.user.getAvatar { (image) in
            cell.logoImage.image = image
        }
        return cell
    }

}

// MARK: - Infomaniak Login Delegate
extension SwitchUserViewController: InfomaniakLoginDelegate {

    func didCompleteLoginWith(code: String, verifier: String) {
        AccountManager.instance.createAndSetCurrentAccount(code: code, codeVerifier: verifier) { (account, error) in
            if account != nil {
                // Download root file
                AccountManager.instance.currentDriveFileManager?.getFile(id: DriveFileManager.constants.rootID) { (_, _, _) in
                    (UIApplication.shared.delegate as! AppDelegate).setRootViewController(MainTabViewController.instantiate())
                }
            } else {
                UIConstants.showSnackBar(message: KDriveStrings.Localizable.errorConnection)
            }
        }
    }

    func didFailLoginWith(error: String) {
        UIConstants.showSnackBar(message: KDriveStrings.Localizable.errorConnection)
    }
}
