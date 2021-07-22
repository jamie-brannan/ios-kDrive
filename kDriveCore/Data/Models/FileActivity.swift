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
import RealmSwift
import UIKit

public enum FileActivityType: String, Codable {
    case fileAccess = "file_access"
    case fileCreate = "file_create"
    case fileRename = "file_rename"
    case fileMoveIn = "file_move"
    case fileMoveOut = "file_move_out"
    case fileTrash = "file_trash"
    case fileRestore = "file_restore"
    case fileDelete = "file_delete"
    case fileUpdate = "file_update"
    case fileFavoriteCreate = "file_favorite_create"
    case fileFavoriteRemove = "file_favorite_remove"
    case fileShareCreate = "file_share_create"
    case fileShareUpdate = "file_share_update"
    case fileShareDelete = "file_share_delete"
    case shareLinkCreate = "share_link_create"
    case shareLinkUpdate = "share_link_update"
    case shareLinkDelete = "share_link_delete"
    case shareLinkShow = "share_link_show"
    case commentCreate = "comment_create"
    case commentUpdate = "comment_update"
    case commentDelete = "comment_delete"
    case commentLike = "comment_like"
    case commentUnlike = "comment_unlike"
    case commentResolve = "comment_resolve"
}

public class FileActivity: Object, Codable {
    @objc private dynamic var rawAction: String = ""
    @objc public dynamic var id: Int = 0
    @objc public dynamic var path: String = ""
    public let userId = RealmProperty<Int?>()
    @objc public dynamic var createdAt: Int = 0
    @objc public dynamic var fileId: Int = 0
    @objc public dynamic var file: File?
    @objc public dynamic var pathNew: String = ""
    @objc public dynamic var oldPath: String = ""
    public var mergedFileActivities: [FileActivity] = []

    public var action: FileActivityType {
        get {
            return FileActivityType(rawValue: rawAction)!
        }
        set {
            rawAction = newValue.rawValue
        }
    }

    public var user: DriveUser? {
        if let id = userId.value {
            return DriveInfosManager.instance.getUser(id: id)
        } else {
            return nil
        }
    }

    public required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rawAction = (try? values.decode(String.self, forKey: .rawAction)) ?? ""
        id = try values.decode(Int.self, forKey: .id)
        path = (try? values.decode(String.self, forKey: .path)) ?? ""
        userId.value = (try? values.decode(DriveUser.self, forKey: .userId))?.id
        createdAt = (try? values.decode(Int.self, forKey: .createdAt)) ?? 0
        fileId = (try? values.decode(Int.self, forKey: .fileId)) ?? 0
        pathNew = (try? values.decode(String.self, forKey: .pathNew)) ?? ""
        oldPath = (try? values.decode(String.self, forKey: .oldPath)) ?? ""
        file = try? values.decode(File.self, forKey: .file)
    }

    override public init() {}

    override public class func primaryKey() -> String? {
        return "id"
    }

    enum CodingKeys: String, CodingKey {
        case rawAction = "action"
        case id
        case path
        case userId = "user"
        case file
        case createdAt = "created_at"
        case fileId = "file_id"
        case pathNew = "new_path"
        case oldPath = "old_path"
    }
}

public class FileDetailActivity: Codable {
    public var action: FileActivityType
    public var id: Int = 0
    public var path: String
    public var user: DriveUser?
    public var createdAt: Int
    public var fileId: Int
    public var newPath: String
    public var oldPath: String

    enum CodingKeys: String, CodingKey {
        case action
        case id
        case path
        case user
        case createdAt = "created_at"
        case fileId = "file_id"
        case newPath = "new_path"
        case oldPath = "old_path"
    }
}

public class FilesActivities: Codable {
    public var activities: [Int: FilesActivitiesContent]

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        var intValue: Int?

        init?(intValue: Int) {
            return nil
        }
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)

        var activities = [Int: FilesActivitiesContent]()
        for key in container.allKeys {
            guard let id = Int(key.stringValue) else { continue }
            activities[id] = try container.decode(FilesActivitiesContent.self, forKey: key)
        }
        self.activities = activities
    }
}

public class FilesActivitiesContent: Codable {
    public var status: ApiResult
    public var activities: [FileActivity]?
    public var error: ApiError?
}
