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

import Foundation
import RealmSwift

public class CategoryRights: EmbeddedObject, Codable {
    @Persisted public var canCreate: Bool
    @Persisted public var canEdit: Bool
    @Persisted public var canDelete: Bool
    @Persisted public var canReadOnFile: Bool
    @Persisted public var canPutOnFile: Bool

    enum CodingKeys: String, CodingKey {
        case canCreate = "can_create"
        case canEdit = "can_edit"
        case canDelete = "can_delete"
        case canReadOnFile = "can_read_on_file"
        case canPutOnFile = "can_put_on_file"
    }
}
