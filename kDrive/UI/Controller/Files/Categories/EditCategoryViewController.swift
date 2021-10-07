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
import UIKit

class EditCategoryViewController: UITableViewController {
    var driveFileManager: DriveFileManager!
    // If we have a category we edit it, otherwise, we create a new one
    var category: kDriveCore.Category?
    /// The file to add the category to after creating it.
    var fileToAdd: File?
    var name = "" {
        didSet {
            guard let footer = tableView.footerView(forSection: tableView.numberOfSections - 1) as? FooterButtonView else {
                return
            }
            footer.footerButton.isEnabled = !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    var color = "#1abc9c"

    private let rows: [Row] = [.name, .color]

    private enum Row: CaseIterable {
        case editInfo, name, color
    }

    private var create: Bool {
        return category == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.register(cellView: FileNameTableViewCell.self)
        tableView.register(cellView: CategoryColorTableViewCell.self)

        title = create ? "Créer une catégorie" : "Modifier une catégorie"

        hideKeyboardWhenTappedAround()
    }

    static func instantiate(driveFileManager: DriveFileManager) -> EditCategoryViewController {
        let viewController = Storyboard.files.instantiateViewController(withIdentifier: "EditCategoryViewController") as! EditCategoryViewController
        viewController.driveFileManager = driveFileManager
        return viewController
    }

    // MARK: - Table view data source

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .editInfo:
            let cell = tableView.dequeueReusableCell(type: FileNameTableViewCell.self, for: indexPath)
            return cell
        case .name:
            let cell = tableView.dequeueReusableCell(type: FileNameTableViewCell.self, for: indexPath)
            cell.textField.setHint("Nom de la catégorie")
            cell.textField.text = category?.name ?? name
            cell.textDidChange = { [unowned self] text in
                if let text = text {
                    if self.create {
                        self.name = text
                    } else {
                        self.category?.name = text
                    }
                }
            }
            cell.textField.becomeFirstResponder()
            return cell
        case .color:
            let cell = tableView.dequeueReusableCell(type: CategoryColorTableViewCell.self, for: indexPath)
            cell.delegate = self
            cell.selectedColor = category?.colorHex
            cell.layoutIfNeeded()
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let view = FooterButtonView.instantiate(title: KDriveStrings.Localizable.buttonSave)
        view.footerButton.isEnabled = !name.trimmingCharacters(in: .whitespaces).isEmpty
        view.delegate = self
        return view
    }
}

// MARK: - Category color delegate

extension EditCategoryViewController: CategoryColorDelegate {
    func didSelectColor(_ color: String) {
        if create {
            self.color = color
        } else {
            category?.colorHex = color
        }
    }
}

// MARK: - Footer button delegate

extension EditCategoryViewController: FooterButtonDelegate {
    @objc func didClickOnButton() {
        if let category = category {
            // Edit category
            driveFileManager.editCategory(id: category.id, name: category.name, color: category.colorHex) { [weak self] result in
                switch result {
                case .success:
                    self?.navigationController?.popViewController(animated: true)
                case .failure(let error):
                    UIConstants.showSnackBar(message: error.localizedDescription)
                }
            }
        } else {
            // Create category
            driveFileManager.createCategory(name: name, color: color) { [weak self] result in
                switch result {
                case .success(let category):
                    // If a file was given, add the new category to it
                    if let file = self?.fileToAdd {
                        self?.driveFileManager.addCategory(file: file, category: category) { error in
                            if let error = error {
                                UIConstants.showSnackBar(message: error.localizedDescription)
                            }
                        }
                    }
                    self?.navigationController?.popViewController(animated: true)
                case .failure(let error):
                    UIConstants.showSnackBar(message: error.localizedDescription)
                }
            }
        }
    }
}
