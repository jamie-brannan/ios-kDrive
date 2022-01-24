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
import UIKit

class ShareLinkSettingsViewController: UIViewController {
    @IBOutlet weak var tableView: UITableView!
    var driveFileManager: DriveFileManager!

    enum OptionsRow: CaseIterable {
        case optionPassword, optionDownload, optionDate

        var title: String {
            switch self {
            case .optionPassword:
                return KDriveResourcesStrings.Localizable.shareLinkPasswordRightTitle
            case .optionDownload:
                return KDriveResourcesStrings.Localizable.shareLinkSettingsAllowDownloadTitle
            case .optionDate:
                return KDriveResourcesStrings.Localizable.allAddExpirationDateTitle
            }
        }

        var fileDescription: String {
            switch self {
            case .optionPassword:
                return KDriveResourcesStrings.Localizable.shareLinkPasswordRightDescription(KDriveResourcesStrings.Localizable.shareLinkTypeFile)
            case .optionDownload:
                return KDriveResourcesStrings.Localizable.shareLinkSettingsAllowDownloadDescription
            case .optionDate:
                return KDriveResourcesStrings.Localizable.shareLinkSettingsAddExpirationDateDescription
            }
        }

        var folderDescription: String {
            switch self {
            case .optionPassword:
                return KDriveResourcesStrings.Localizable.shareLinkPasswordRightDescription(KDriveResourcesStrings.Localizable.shareLinkTypeFolder)
            case .optionDownload:
                return KDriveResourcesStrings.Localizable.shareLinkSettingsAllowDownloadDescription
            case .optionDate:
                return KDriveResourcesStrings.Localizable.shareLinkSettingsAddExpirationDateDescription
            }
        }

        func isEnabled(drive: Drive) -> Bool {
            if self == .optionDate && drive.pack == .free {
                return false
            } else if self == .optionPassword && drive.pack == .free {
                return false
            } else {
                return true
            }
        }
    }

    var file: File!
    var shareFile: SharedFile!
    private var settings = [OptionsRow: Bool]()
    private var settingsValue = [OptionsRow: Any?]()
    var accessRightValue: String!
    var editRights = Right.onlyOfficeRights
    var editRightValue: String = ""
    var optionsRows: [OptionsRow] = [.optionPassword, .optionDownload, .optionDate]
    var password: String?
    private var newPassword = false
    var enableButton = true {
        didSet {
            guard let footer = tableView.footerView(forSection: tableView.numberOfSections - 1) as? FooterButtonView else {
                return
            }
            footer.footerButton.isEnabled = enableButton
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = KDriveResourcesStrings.Localizable.fileShareLinkSettingsTitle

        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(cellView: ShareLinkAccessRightTableViewCell.self)
        tableView.register(cellView: ShareLinkSettingTableViewCell.self)
        tableView.separatorColor = .clear

        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always

        hideKeyboardWhenTappedAround()
        initOptions()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc func keyboardWillShow(_ notification: Notification) {
        if let keyboardSize = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            tableView.contentInset.bottom = keyboardSize.height

            UIView.animate(withDuration: 0.1) {
                self.view.layoutIfNeeded()
            }
        }
    }

    @objc func keyboardWillHide(_ notification: Notification) {
        tableView.contentInset.bottom = 0
        UIView.animate(withDuration: 0.1) {
            self.view.layoutIfNeeded()
        }
    }

    func updateButton() {
        var activateButton = true
        for (option, enabled) in settings {
            // Disable the button if the option is enabled but has no value, except in case of password
            if enabled && (option != .optionDownload && getValue(for: option) == nil) && (option != .optionPassword || !newPassword) {
                activateButton = false
            }
        }
        enableButton = activateButton
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let navigationBarAppearanceStandard = UINavigationBarAppearance()
        navigationBarAppearanceStandard.configureWithTransparentBackground()
        navigationBarAppearanceStandard.backgroundColor = KDriveResourcesAsset.backgroundCardViewColor.color
        navigationItem.standardAppearance = navigationBarAppearanceStandard

        let navigationBarAppearanceLarge = UINavigationBarAppearance()
        navigationBarAppearanceLarge.configureWithTransparentBackground()
        navigationBarAppearanceLarge.backgroundColor = KDriveResourcesAsset.backgroundCardViewColor.color
        navigationItem.scrollEdgeAppearance = navigationBarAppearanceLarge
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tableView.reloadData()
        MatomoUtils.track(view: ["ShareAndRights", "ShareLinkSettings"])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setInfomaniakAppearanceNavigationBar()
    }

    private func initOptions() {
        guard shareFile != nil else { return }
        // Access right
        accessRightValue = shareFile.link!.permission
        // Edit right
        editRightValue = shareFile.link!.canEdit ? EditPermission.write.rawValue : EditPermission.read.rawValue
        // Options
        settings = [
            .optionPassword: shareFile.link!.permission == ShareLinkPermission.password.rawValue,
            .optionDownload: !shareFile.link!.blockDownloads,
            .optionDate: shareFile.link!.validUntil != nil
        ]
        var date: Date?
        if let timeInterval = shareFile.link!.validUntil {
            date = Date(timeIntervalSince1970: Double(timeInterval))
        }
        settingsValue = [
            .optionPassword: nil,
            .optionDownload: nil,
            .optionDate: date
        ]
        if shareFile.link!.permission == ShareLinkPermission.password.rawValue {
            newPassword = true
        }
    }

    private func getSetting(for option: OptionsRow) -> Bool {
        return settings[option] ?? false
    }

    private func getValue(for option: OptionsRow) -> Any? {
        return settingsValue[option] ?? nil
    }

    class func instantiate() -> ShareLinkSettingsViewController {
        return Storyboard.files.instantiateViewController(withIdentifier: "ShareLinkSettingsViewController") as! ShareLinkSettingsViewController
    }

    // MARK: - State restoration

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)

        coder.encode(driveFileManager.drive.id, forKey: "DriveId")
        coder.encode(file.id, forKey: "FileId")
        coder.encode(shareFile, forKey: "ShareFile")
    }

    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)

        let driveId = coder.decodeInteger(forKey: "DriveId")
        let fileId = coder.decodeInteger(forKey: "FileId")
        shareFile = coder.decodeObject(forKey: "ShareFile") as? SharedFile
        guard let driveFileManager = AccountManager.instance.getDriveFileManager(for: driveId, userId: AccountManager.instance.currentUserId) else {
            return
        }
        self.driveFileManager = driveFileManager
        file = driveFileManager.getCachedFile(id: fileId)
        // Update UI
        initOptions()
        updateButton()
        tableView.reloadData()
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource

extension ShareLinkSettingsViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return (file.isOfficeFile || file.isDirectory) ? optionsRows.count + 1 : optionsRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // Access right
        if indexPath.row == 0 && (file.isOfficeFile || file.isDirectory) {
            let cell = tableView.dequeueReusableCell(type: ShareLinkAccessRightTableViewCell.self, for: indexPath)
            cell.accessRightLabel.text = nil
            cell.accessRightImage.image = nil
            if let right = editRights.first(where: { $0.key == editRightValue }) {
                cell.accessRightView.accessibilityLabel = right.title
                cell.accessRightLabel.text = right.title
                cell.accessRightImage.image = right.icon
            }
            return cell
        }
        // Options
        let cell = tableView.dequeueReusableCell(type: ShareLinkSettingTableViewCell.self, for: indexPath)
        cell.delegate = self
        let option = (file.isOfficeFile || file.isDirectory) ? optionsRows[indexPath.row - 1] : optionsRows[indexPath.row]
        let index = (file.isOfficeFile || file.isDirectory) ? indexPath.row - 1 : indexPath.row
        cell.configureWith(index: index, option: option, switchValue: getSetting(for: option), settingValue: getValue(for: option), drive: driveFileManager.drive, actionButtonVisible: option == .optionPassword && newPassword, isFolder: file.isDirectory)

        if !option.isEnabled(drive: driveFileManager.drive) {
            cell.actionHandler = { [weak self] _ in
                guard let self = self else { return }
                let driveFloatingPanelController = SecureLinkFloatingPanelViewController.instantiatePanel()
                let floatingPanelViewController = driveFloatingPanelController.contentViewController as? SecureLinkFloatingPanelViewController
                floatingPanelViewController?.rightButton.isEnabled = self.driveFileManager.drive.accountAdmin
                floatingPanelViewController?.actionHandler = { _ in
                    driveFloatingPanelController.dismiss(animated: true) {
                        StorePresenter.showStore(from: self, driveFileManager: self.driveFileManager)
                    }
                }
                self.present(driveFloatingPanelController, animated: true)
            }
        }

        return cell
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        if section == tableView.numberOfSections - 1 {
            return 124
        }
        return 28
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        if section == tableView.numberOfSections - 1 {
            let view = FooterButtonView.instantiate(title: KDriveResourcesStrings.Localizable.buttonSave)
            view.delegate = self
            view.footerButton.isEnabled = enableButton
            view.background.backgroundColor = tableView.backgroundColor
            return view
        }
        return nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.row == 0 && (file.isOfficeFile || file.isDirectory) {
            let rightsSelectionViewController = RightsSelectionViewController.instantiateInNavigationController(file: file, driveFileManager: driveFileManager)
            rightsSelectionViewController.modalPresentationStyle = .fullScreen
            if let rightsSelectionVC = rightsSelectionViewController.viewControllers.first as? RightsSelectionViewController {
                rightsSelectionVC.selectedRight = editRightValue
                rightsSelectionVC.rightSelectionType = .officeOnly
                rightsSelectionVC.delegate = self
            }
            present(rightsSelectionViewController, animated: true)
        }
    }
}

// MARK: - ShareLinkSettingsDelegate

extension ShareLinkSettingsViewController: ShareLinkSettingsDelegate {
    func didUpdateSettings(index: Int, isOn: Bool) {
        let option = optionsRows[index]
        settings[option] = isOn
        tableView.reloadRows(at: [IndexPath(row: (file.isOfficeFile || file.isDirectory) ? index + 1 : index, section: 0)], with: .automatic)
        updateButton()
    }

    func didUpdateSettingsValue(index: Int, content: Any?) {
        let option = optionsRows[index]
        settingsValue[option] = content
        updateButton()
    }

    func didTapOnActionButton(index: Int) {
        let option = optionsRows[index]
        if option == .optionPassword {
            newPassword.toggle()
        }
        tableView.reloadRows(at: [IndexPath(row: (file.isOfficeFile || file.isDirectory) ? index + 1 : index, section: 0)], with: .automatic)
        updateButton()
    }
}

// MARK: - RightsSelectionDelegate

extension ShareLinkSettingsViewController: RightsSelectionDelegate {
    func didUpdateRightValue(newValue value: String) {
        editRightValue = value
        updateButton()
    }
}

// MARK: - FooterButtonDelegate

extension ShareLinkSettingsViewController: FooterButtonDelegate {
    func didClickOnButton() {
        let permission = getSetting(for: .optionPassword) ? ShareLinkPermission.password.rawValue : ShareLinkPermission.public.rawValue
        let password = getSetting(for: .optionPassword) ? (getValue(for: .optionPassword) as? String) : ""
        let date = getSetting(for: .optionDate) ? (getValue(for: .optionDate) as? Date) : nil
        let validUntil = date?.timeIntervalSince1970
        let canEdit = editRightValue == Right.onlyOfficeRights[1].key
        driveFileManager.apiFetcher.updateShareLinkWith(file: file, canEdit: canEdit, permission: permission, password: password, date: validUntil, blockDownloads: !getSetting(for: .optionDownload), blockComments: !canEdit, isFree: driveFileManager.drive.pack == .free) { response, _ in
            if response?.data == true {
                self.navigationController?.popViewController(animated: true)
            }
        }
    }
}
