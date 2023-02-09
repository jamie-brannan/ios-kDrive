/*
 Infomaniak kDrive - iOS App
 Copyright (C) 2023 Infomaniak Network SA

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

/// Tracks the upload of a chunk
final public class UploadChunkTask: Object {
    @Persisted public var chunk: UploadedChunk?
    
    @Persisted public var chunkNumber: Int64?
    @Persisted public var chunkSize: Int64?
    @Persisted public var chunkHash: String?
    @Persisted public var sessionToken: String?
    @Persisted public var path: String?
    
    @Persisted public var rangeLowBound: Int64?
    @Persisted public var rangeHiBound: Int64?
    
    public var range: DataRange? {
        guard let rangeLowBound, let rangeHiBound else {
            return nil
        }
        return UInt64(rangeLowBound)...UInt64(rangeHiBound)
    }
}
