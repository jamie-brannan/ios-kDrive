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

import DropDown
import kDriveCore
import UIKit

class ShareAndRightsViewController: UIViewController {
    @IBOutlet weak var tableView: UITableView!

    private enum ShareAndRightsSections: CaseIterable {
        case invite
        case link
        case access
    }

    private let sections = ShareAndRightsSections.allCases

    private var shareLinkIsActive = false
    private var removeUsers: [Int] = []
    private var removeEmails: [String] = []
    private var selectedUserIndex: Int?
    private var selectedTeamIndex: Int?
    private var selectedInvitationIndex: Int?
    private var shareLinkRights = false
    private var initialLoading = true

    var file: File!
    var sharedFile: SharedFile?

    var driveFileManager: DriveFileManager!

    override func viewDidLoad() {
        super.viewDidLoad()
        // Documentation says it's better to put it in AppDelegate but why ?
        DropDown.startListeningToKeyboard()

        navigationController?.navigationBar.isTranslucent = true

        tableView.register(cellView: InviteUserTableViewCell.self)
        tableView.register(cellView: UsersAccessTableViewCell.self)
        tableView.register(cellView: ShareLinkTableViewCell.self)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: UIConstants.listPaddingBottom, right: 0)

        updateShareList()
        hideKeyboardWhenTappedAround()
        setTitle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !initialLoading {
            updateShareList()
        }
        initialLoading = false
    }

    private func setTitle() {
        guard file != nil else { return }
        title = file.isDirectory ? KDriveStrings.Localizable.fileShareDetailsFolderTitle(file.name) : KDriveStrings.Localizable.fileShareDetailsFileTitle(file.name)
    }

    private func updateShareList() {
        driveFileManager?.apiFetcher.getShareListFor(file: file) { response, error in
            if let sharedFile = response?.data {
                self.sharedFile = sharedFile
                sharedFile.teams.sort()
                self.removeUsers = sharedFile.users.map(\.id) + sharedFile.invitations.compactMap { $0?.userId }
                self.removeEmails = sharedFile.invitations.compactMap { $0?.userId != nil ? nil : $0?.email }
                self.tableView.reloadData()
            } else {
                print(error)
            }
        }
    }

    private func showRightsSelection(selectedPermission: UserPermission, userType: RightsSelectionViewController.UserType, user: DriveUser? = nil, invitation: Invitation? = nil, team: Team? = nil) {
        let rightsSelectionViewController = RightsSelectionViewController.instantiateInNavigationController()
        rightsSelectionViewController.modalPresentationStyle = .fullScreen
        if let rightsSelectionVC = rightsSelectionViewController.viewControllers.first as? RightsSelectionViewController {
            rightsSelectionVC.driveFileManager = driveFileManager
            rightsSelectionVC.delegate = self
            rightsSelectionVC.selectedRight = selectedPermission.rawValue
            rightsSelectionVC.user = user
            rightsSelectionVC.invitation = invitation
            rightsSelectionVC.team = team
            rightsSelectionVC.userType = userType
        }
        present(rightsSelectionViewController, animated: true)
    }

    @IBAction func closeButtonPressed(_ sender: Any) {
        _ = navigationController?.popViewController(animated: true)
    }

    class func instantiate() -> ShareAndRightsViewController {
        return Storyboard.files.instantiateViewController(withIdentifier: "ShareAndRightsViewController") as! ShareAndRightsViewController
    }

    // MARK: - State restoration

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)

        coder.encode(driveFileManager.drive.id, forKey: "DriveId")
        coder.encode(file.id, forKey: "FileId")
    }

    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)

        let driveId = coder.decodeInteger(forKey: "DriveId")
        let fileId = coder.decodeInteger(forKey: "FileId")
        guard let driveFileManager = AccountManager.instance.getDriveFileManager(for: driveId, userId: AccountManager.instance.currentUserId) else {
            return
        }
        self.driveFileManager = driveFileManager
        file = driveFileManager.getCachedFile(id: fileId)
        setTitle()
        updateShareList()
    }
}

// MARK: - Table view delegate & data source

extension ShareAndRightsViewController: UITableViewDelegate, UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch sections[section] {
        case .link:
            return 5
        case .invite, .access:
            return UITableView.automaticDimension
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        return 100
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .invite, .link:
            return 1
        case .access:
            if let sharedFile = sharedFile {
                return sharedFile.users.count + sharedFile.invitations.count + sharedFile.teams.count
            } else {
                return 0
            }
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .invite:
            let cell = tableView.dequeueReusableCell(type: InviteUserTableViewCell.self, for: indexPath)
            cell.initWithPositionAndShadow(isFirst: true, isLast: true)
            cell.drive = driveFileManager?.drive
            cell.removeUsers = removeUsers
            cell.removeEmails = removeEmails
            cell.delegate = self
            return cell
        case .link:
            let cell = tableView.dequeueReusableCell(type: ShareLinkTableViewCell.self, for: indexPath)
            cell.initWithPositionAndShadow(isFirst: true, isLast: true, radius: 6)
            cell.delegate = self
            cell.configureWith(sharedFile: sharedFile, isOfficeFile: file?.isOfficeFile ?? false, enabled: (file?.rights?.canBecomeLink ?? false) || file?.shareLink != nil)
            return cell
        case .access:
            let cell = tableView.dequeueReusableCell(type: UsersAccessTableViewCell.self, for: indexPath)
            cell.initWithPositionAndShadow(isFirst: indexPath.row == 0, isLast: indexPath.row == self.tableView(tableView, numberOfRowsInSection: indexPath.section) - 1, radius: 6)
            let sharedFile = sharedFile!
            if indexPath.row < sharedFile.teams.count {
                cell.configureWith(team: sharedFile.teams[indexPath.row], drive: driveFileManager.drive)
            } else if indexPath.row < (sharedFile.teams.count + sharedFile.users.count) {
                let index = indexPath.row - sharedFile.teams.count
                cell.configureWith(user: sharedFile.users[index], blocked: AccountManager.instance.currentUserId == sharedFile.users[index].id)
            } else {
                let index = indexPath.row - (sharedFile.teams.count + sharedFile.users.count)
                cell.configureWith(invitation: sharedFile.invitations[index]!)
            }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .invite:
            break
        case .link:
            break
        case .access:
            shareLinkRights = false
            selectedUserIndex = nil
            selectedTeamIndex = nil
            selectedInvitationIndex = nil

            guard let sharedFile = sharedFile else { return }

            if indexPath.row < sharedFile.teams.count {
                // Team selected
                let team = sharedFile.teams[indexPath.row]
                selectedTeamIndex = indexPath.row
                showRightsSelection(selectedPermission: team.right ?? .read, userType: .team, team: team)
            } else if indexPath.row < (sharedFile.teams.count + sharedFile.users.count) {
                // User selected
                let index = indexPath.row - sharedFile.teams.count
                let user = sharedFile.users[index]
                if user.id == AccountManager.instance.currentUserId {
                    break
                }
                selectedUserIndex = index
                showRightsSelection(selectedPermission: user.permission ?? .read, userType: .user, user: user)
            } else {
                // Invitation selected
                let index = indexPath.row - (sharedFile.teams.count + sharedFile.users.count)
                let invitation = sharedFile.invitations[index]!
                selectedInvitationIndex = index
                showRightsSelection(selectedPermission: invitation.permission, userType: .invitation, invitation: invitation)
            }
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch sections[section] {
        case .invite, .link:
            return nil
        case .access:
            return NewFolderSectionHeaderView.instantiate(title: KDriveStrings.Localizable.fileShareDetailsUsersAccesTitle)
        }
    }
}

// MARK: - Rights selection delegate

extension ShareAndRightsViewController: RightsSelectionDelegate {
    func didUpdateRightValue(newValue value: String) {
        guard let sharedFile = sharedFile else { return }

        if let sharedLink = sharedFile.link, shareLinkRights {
            driveFileManager.apiFetcher.updateShareLinkWith(file: file, canEdit: value == "write", permission: sharedLink.permission, date: sharedLink.validUntil != nil ? TimeInterval(sharedLink.validUntil!) : nil, blockDownloads: sharedLink.blockDownloads, blockComments: sharedLink.blockComments, blockInformation: sharedLink.blockInformation, isFree: driveFileManager.drive.pack == .free) { _, _ in
            }
        } else if let index = selectedUserIndex {
            driveFileManager.apiFetcher.updateUserRights(file: file, user: sharedFile.users[index], permission: value) { response, _ in
                if response?.data != nil {
                    self.sharedFile!.users[index].permission = UserPermission(rawValue: value)
                    self.tableView.reloadRows(at: [IndexPath(row: index + sharedFile.teams.count, section: 2)], with: .automatic)
                }
            }
        } else if let index = selectedInvitationIndex {
            driveFileManager.apiFetcher.updateInvitationRights(driveId: driveFileManager.drive.id, invitation: sharedFile.invitations[index]!, permission: value) { response, _ in
                if response?.data != nil {
                    self.sharedFile?.invitations[index]?.permission = UserPermission(rawValue: value)!
                    self.tableView.reloadRows(at: [IndexPath(row: index + sharedFile.teams.count + sharedFile.users.count, section: 2)], with: .automatic)
                }
            }
        } else if let index = selectedTeamIndex {
            driveFileManager.apiFetcher.updateTeamRights(file: file, team: sharedFile.teams[index], permission: value) { response, _ in
                if response?.data != nil {
                    self.sharedFile?.teams[index].right = UserPermission(rawValue: value)
                    self.tableView.reloadRows(at: [IndexPath(row: index, section: 2)], with: .automatic)
                }
            }
        }
    }

    func didDeleteUserRight() {
        guard let sharedFile = sharedFile else { return }

        if let index = selectedUserIndex {
            driveFileManager.apiFetcher.deleteUserRights(file: file, user: sharedFile.users[index]) { response, _ in
                if response?.data != nil {
                    self.tableView.reloadSections([0, 2], with: .automatic)
                }
            }
        } else if let index = selectedInvitationIndex {
            driveFileManager.apiFetcher.deleteInvitationRights(driveId: driveFileManager.drive.id, invitation: sharedFile.invitations[index]!) { response, _ in
                if response?.data != nil {
                    self.tableView.reloadSections([0, 2], with: .automatic)
                }
            }
        } else if let index = selectedTeamIndex {
            driveFileManager.apiFetcher.deleteTeamRights(file: file, team: sharedFile.teams[index]) { response, _ in
                if response?.data != nil {
                    self.tableView.reloadSections([0, 2], with: .automatic)
                }
            }
        }
    }
}

// MARK: - Share link table view cell delegate

extension ShareAndRightsViewController: ShareLinkTableViewCellDelegate {
    func shareLinkSharedButtonPressed(link: String, sender: UIView) {
        let items = [URL(string: link)!]
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = sender
        present(ac, animated: true)
    }

    func shareLinkRightsButtonPressed() {
        guard let sharedLink = sharedFile?.link else { return }

        let rightsSelectionViewController = RightsSelectionViewController.instantiateInNavigationController()
        rightsSelectionViewController.modalPresentationStyle = .fullScreen
        if let rightsSelectionVC = rightsSelectionViewController.viewControllers.first as? RightsSelectionViewController {
            rightsSelectionVC.driveFileManager = driveFileManager
            rightsSelectionVC.delegate = self
            rightsSelectionVC.rightSelectionType = .officeOnly
            rightsSelectionVC.selectedRight = sharedLink.canEdit ? "write" : "read"
        }
        shareLinkRights = true
        present(rightsSelectionViewController, animated: true)
    }

    func shareLinkSettingsButtonPressed() {
        let shareLinkSettingsViewController = ShareLinkSettingsViewController.instantiate()
        shareLinkSettingsViewController.driveFileManager = driveFileManager
        shareLinkSettingsViewController.file = file
        shareLinkSettingsViewController.shareFile = sharedFile
        navigationController?.pushViewController(shareLinkSettingsViewController, animated: true)
    }

    func shareLinkSwitchToggled(isOn: Bool) {
        if isOn {
            driveFileManager.activateShareLink(for: file) { _, shareLink, _ in
                if let link = shareLink {
                    self.sharedFile?.link = link
                    self.tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .automatic)
                }
            }
        } else {
            driveFileManager.removeShareLink(for: file) { file, _ in
                if file != nil {
                    self.sharedFile?.link = nil
                    self.tableView.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .automatic)
                }
            }
        }
    }
}

// MARK: - Search user delegate

extension ShareAndRightsViewController: SearchUserDelegate {
    func didSelectUser(user: DriveUser) {
        let inviteUserViewController = InviteUserViewController.instantiateInNavigationController()
        inviteUserViewController.modalPresentationStyle = .fullScreen
        if let inviteUserVC = inviteUserViewController.viewControllers.first as? InviteUserViewController {
            inviteUserVC.driveFileManager = driveFileManager
            inviteUserVC.users.append(user)
            inviteUserVC.file = file
            inviteUserVC.removeEmails = removeEmails
            inviteUserVC.removeUsers = removeUsers + [user.id]
        }
        present(inviteUserViewController, animated: true)
    }

    func didSelectEmail(email: String) {
        let inviteUserViewController = InviteUserViewController.instantiateInNavigationController()
        inviteUserViewController.modalPresentationStyle = .fullScreen
        if let inviteUserVC = inviteUserViewController.viewControllers.first as? InviteUserViewController {
            inviteUserVC.driveFileManager = driveFileManager
            inviteUserVC.emails.append(email)
            inviteUserVC.file = file
            inviteUserVC.removeEmails = removeEmails + [email]
            inviteUserVC.removeUsers = removeUsers
        }
        present(inviteUserViewController, animated: true)
    }
}
