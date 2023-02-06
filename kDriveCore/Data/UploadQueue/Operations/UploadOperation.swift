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

import Alamofire
import FileProvider
import Foundation
import InfomaniakCore
import InfomaniakDI
import RealmSwift
import Sentry
import UIKit

/// The current step of the upload with chunks operation
enum UploadOperationStep {
    case `init`
    case startup
    case fetchSession
    case chunking
    case schedullingUpload
    case completionHandler // ? move to linked op ?
}

public struct UploadCompletionResult {
    var uploadFile: UploadFile!
    var driveFile: File?
}

public final class UploadOperation: AsynchronousOperation, UploadOperationable {
    // MARK: - Attributes

    @LazyInjectService var uploadQueue: UploadQueueable
    @LazyInjectService var uploadNotifiable: UploadNotifiable
    @LazyInjectService var uploadProgressable: UploadProgressable

    @LazyInjectService var accountManager: AccountManageable

    @LazyInjectService var uploadTokenManager: UploadTokenManager
    @LazyInjectService var photoLibraryUploader: PhotoLibraryUploader

    #warning("⚠️ prolly should be replaced by a weak var passed at init, leak otherwise.")
    @LazyInjectService var backgroundUploadManager: BackgroundUploadSessionManager
    
    var step: UploadOperationStep {
        didSet {
            ABLog("~> moved to step:\(step) for: \n \(self.debugDescription)")
        }
    }
    
    public override var debugDescription: String {
        """
        <\(type(of: self)):\(super.debugDescription)
        uploading file:'\(file)'
        step: '\(step)'>
        """
    }
    
    var file: UploadFile
    var uploadTasks = [String: URLSessionUploadTask]()
    
    private let urlSession: FileUploadSession
    private let itemIdentifier: NSFileProviderItemIdentifier?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid // ? Can I remove UIkit code from this ?
    private var uploadToken: UploadToken?
    private var progressObservation: NSKeyValueObservation?

    public var result: UploadCompletionResult

    private let completionLock = DispatchGroup()

    // MARK: - Public methods

    public required init(file: UploadFile,
                         urlSession: FileUploadSession = URLSession.shared,
                         itemIdentifier: NSFileProviderItemIdentifier? = nil) {
        self.file = UploadFile(value: file)
        self.urlSession = urlSession
        self.itemIdentifier = itemIdentifier
        self.result = UploadCompletionResult()
        self.step = .`init`
    }

    // Restore the operation after BG work
    public required init(file: UploadFile,
                         task: URLSessionUploadTask,
                         urlSession: FileUploadSession = URLSession.shared) {
        self.file = UploadFile(value: file)
        self.file.error = nil
        self.urlSession = urlSession
        self.itemIdentifier = nil
        self.result = UploadCompletionResult()
        self.step = .completionHandler
        
        let key = task.currentRequest?.url?.absoluteString ?? UUID().uuidString
        self.uploadTasks[key] = task
    }

    override public func execute() async {
        self.step = .startup
        ABLog("[UploadOperation] Job \(file.id) started")
        // Always check for cancellation before launching the task
        if isCancelled {
            ABLog("[UploadOperation] Job \(file.id) canceled")
            // Must move the operation to the finished state if it is canceled.
            file.error = .taskCancelled
            end()
            return
        }

        // Start background task
        // TODO: Ask again about creating only one in the Queue. This is not the NSURLSessionBG Identifier, 30 sec could be split between all tasks. check.
        if !Bundle.main.isExtension {
            backgroundTaskIdentifier = await UIApplication.shared.beginBackgroundTask(withName: "File Uploader",
                                                                                      expirationHandler: backgroundTaskExpired)
        }

        // Fetch content from local library if needed
        getPhAssetIfNeeded()

        ABLog("[UploadOperation] Fetching Token \(file.id)")
        file.maxRetryCount -= 1 // TODO: ? what does it mean ?
//        guard let token = uploadToken else {
//            ABLog("[UploadOperation] Failed to fetch upload token for job \(file.id)", level: .error)
//            file.error = .refreshToken
//            end()
//            return
//        }

        guard let driveFileManager = accountManager.getDriveFileManager(for: accountManager.currentDriveId,
                                                                        userId: accountManager.currentUserId) else {
            file.error = .refreshToken
            ABLog("[UploadOperation] Failed to getDriveFileManager fid:\(file.id) userId:\(accountManager.currentUserId)",
                  level: .error)
            file.error = .localError
            end()
            return
        }

        let apiFetcher = driveFileManager.apiFetcher
        let drive = driveFileManager.drive

        // Check file is readable
        guard let fileUrl = file.pathURL,
              FileManager.default.fileExists(atPath: fileUrl) else {
            ABLog("[UploadOperation] File has not a valid readable URL \(String(describing: file.pathURL)) for \(file.id)", level: .error)
            file.error = .fileNotFound
            end()
            return
        }

        // Load ranges of the file
        let rangeProvider = RangeProvider(fileURL: fileUrl)
        let fileSize: UInt64
        let ranges: [DataRange]
        do {
            fileSize = try rangeProvider.fileSize
            ranges = try rangeProvider.allRanges
        } catch {
            ABLog("[UploadOperation] Unable to acquire ranges for \(file.id)", level: .error)
            file.error = .localError
            end()
            return
        }

        self.step = .fetchSession
        let session: UploadSession
        do {
            // Get a valid upload session
            session = try await apiFetcher.startSession(drive: drive,
                                                        totalSize: fileSize,
                                                        fileName: file.name,
                                                        totalChunks: ranges.count,
                                                        conflictResolution: .throwError,
                                                        directoryID: file.parentDirectoryId)
        } catch {
            ABLog("[UploadOperation] Unable to get an UploadSession for \(file.id)", level: .error)
            file.error = .refreshToken
            end()
            return
        }
        
        // Save session linked to an upload file + date to invalidate
//        BackgroundRealm.uploads.execute { uploadsRealm in
//            try? uploadsRealm.safeWrite {
//                uploadsRealm.add(UploadFile(value: file), update: .modified)
//            }
//        }
        

        // Chunks creation from ranges
        guard let chunkProvider = ChunkProvider(fileURL: fileUrl, ranges: ranges) else {
            ABLog("[UploadOperation] Unable to get a ChunkProvider for \(file.id)", level: .error)
            file.error = .localError
            end()
            return
        }

        // generate and store chunks asap.
        self.step = .chunking
        var index: Int = 0
        // TODO: store in DB, temp inmemory structure
        typealias RequestParams = (chunkNumber: Int, chunkSize: Int, chunkHash: String, sessionToken: String, path: URL)
        var resquestBuilder = [RequestParams]()
        while let chunk = chunkProvider.next() {
            ABLog("[UploadOperation] Storing Chunk [\(index)] \(file.id)")
            do {
                if isCancelled {
                    ABLog("[UploadOperation] Job \(file.id) canceled")
                    // Must move the operation to the finished state if it is canceled.
                    file.error = .taskCancelled
                    end()
                    return
                }
                
                let chunkPath = try storeChunk(chunk, index: index, file: file)
                let chunkHash = "sha256:\(chunk.SHA256DigestString)"
                let params: RequestParams = (chunkNumber: index, chunkSize: chunk.count, chunkHash: chunkHash, sessionToken: session.token.token, path: chunkPath)
                resquestBuilder.append(params)
                
                // TODO: store `RequestParams` in DB
                // Save UploadFile state
//                if index/4 == 0 { // ? Store at every step ?
//                    BackgroundRealm.uploads.execute { uploadsRealm in
//                        try? uploadsRealm.safeWrite {
//                            uploadsRealm.add(UploadFile(value: file), update: .modified)
//                        }
//                    }
//                }
                
            } catch {
                ABLog("[UploadOperation] Unable to save a chunk to storage idx:\(index) \(file.id)", level: .error)
                file.error = .localError
                end()
                return
            }
            index += 1
        }
        
        // schedule all the chunks to be uploaded
        // TODO: read request params from DB
        self.step = .schedullingUpload
        for (index, params) in resquestBuilder.enumerated() {
            do {
                let request = try buildRequest(chunkNumber: params.0, chunkSize: params.1, chunkHash: params.2, sessionToken: params.3)
                let uploadTask = urlSession.uploadTask(with: request, fromFile: params.4, completionHandler: uploadCompletion)
                // Extra 512 bytes for request headers
                uploadTask.countOfBytesClientExpectsToSend = file.size + 512
                // 5KB is a very reasonable upper bound size for a file server response (max observed: 1.47KB)
                uploadTask.countOfBytesClientExpectsToReceive = 1024 * 5
                
                // TODO: handle progress observation somewhere over here
                
                uploadTasks[params.4.absoluteString] = uploadTask
                uploadTask.resume()
            }
            catch {
                ABLog("[UploadOperation] Unable to create an upload request for chunk \(params) - \(file.id)", level: .error)
                file.error = .localError
                end()
                return
            }
        }
        
        // schedulle upload of chunks
//        let uploadedChunk = try await apiFetcher.appendChunk(drive: drive,
//                                                             sessionToken: session.token,
//                                                             chunkNumber: index,
//                                                             chunk: chunk)
        
//        // Save UploadFile state (we are mainly interested in saving sessionUrl)
//        BackgroundRealm.uploads.execute { uploadsRealm in
//            try? uploadsRealm.safeWrite {
//                uploadsRealm.add(UploadFile(value: file), update: .modified)
//            }
//        }
        
        // LEGACY
        /*
        let url = Endpoint.directUpload(file: file).url
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")

        file.sessionUrl = url.absoluteString
        file.sessionId = urlSession.identifier

        if let filePath = file.pathURL,
           FileManager.default.isReadableFile(atPath: filePath.path) {
            let uploadTask = urlSession.uploadTask(with: request, fromFile: filePath, completionHandler: uploadCompletion)
            task = uploadTask

            uploadTask.countOfBytesClientExpectsToSend = file.size + 512 // Extra 512 bytes for request headers
            uploadTask.countOfBytesClientExpectsToReceive = 1024 * 5 // 5KB is a very reasonable upper bound size for a file server response (max observed: 1.47KB)

            progressObservation = uploadTask.progress.observe(\.fractionCompleted, options: .new) { [fileId = file.id] _, value in
                guard let newValue = value.newValue else {
                    return
                }
                self.uploadProgressable.publishProgress(newValue, for: fileId)
            }
            if let itemIdentifier = itemIdentifier {
                DriveInfosManager.instance.getFileProviderManager(driveId: file.driveId, userId: file.userId) { manager in
                    manager.register(uploadTask, forItemWithIdentifier: itemIdentifier) { _ in }
                }
            }
            uploadTask.resume()

            // Save UploadFile state (we are mainly interested in saving sessionUrl)
            BackgroundRealm.uploads.execute { uploadsRealm in
                try? uploadsRealm.safeWrite {
                    uploadsRealm.add(UploadFile(value: file), update: .modified)
                }
            }
        } else {
//            ABLog("[UploadOperation] No file path found for job \(file.id)", level: .error)
//            file.error = .fileNotFound
//            end()
        }
         */
    }

    // MARK: - Private methods
    
    // MARK: Build request
    
//    func buildRequest(chunkNumber: Int,
//                      sessionToken: String,
//                      chunk: Data) throws -> URLRequest {
//        let chunkSize = chunk.count
//        let chunkHash = "sha256:\(chunk.SHA256DigestString)"
//        return try buildRequest(chunkNumber: chunkNumber,
//                                chunkSize: chunkSize,
//                                chunkHash: chunkHash,
//                                sessionToken: sessionToken)
//    }
    
    func buildRequest(chunkNumber: Int,
                      chunkSize: Int,
                      chunkHash: String,
                      sessionToken: String) throws -> URLRequest {
        let parameters: [String: String] = [DriveApiFetcher.APIParameters.chunkNumber.rawValue: "\(chunkNumber)",
                                            DriveApiFetcher.APIParameters.chunkSize.rawValue: "\(chunkSize)",
                                            DriveApiFetcher.APIParameters.chunkHash.rawValue: chunkHash]
        let route: Endpoint = .appendChunk(drive: AbstractDriveWrapper(id: accountManager.currentDriveId),
                                           sessionToken: AbstractTokenWrapper(token: sessionToken))
        
        let headers = HTTPHeaders(parameters)
        return try URLRequest(url: route.url, method: .post, headers: headers)
    }
    
    // MARK: Chunks
    
    func storeChunk(_ buffer: Data, index: Int, file: UploadFile) throws -> URL {
        let fileUrlString = buildChunkPath(index: index, file: file)
        let absoluteChunkPath = URL(fileURLWithPath: fileUrlString)

        try storeChunk(buffer, destination: absoluteChunkPath)
        return absoluteChunkPath
    }
    
    private func buildChunkPath(index: Int, file: UploadFile) -> String {
        // NSTemporaryDirectory is perfect for this use case.
        // Cleaned after ≈ 3 days, our session is valid 12h.
        // https://cocoawithlove.com/2009/07/temporary-files-and-folders-in-cocoa.html
        
        // TODO: add /*+ session ID*/ in folder
        NSTemporaryDirectory() + "/\(file.id)/" + chunkName(index: index, file: file)
    }
    
    private func chunkName(index: Int, file: UploadFile) -> String {
        "upload_\(file.id)_\(index).part"/* TODO: + session ID */
    }
    
    private func storeChunk(_ buffer: Data, destination: URL) throws {
        try buffer.write(to: destination, options:[.atomic])
    }

    // MARK: PHAssets
    
    private func getPhAssetIfNeeded() {
        if file.type == .phAsset && file.pathURL == nil {
            ABLog("[UploadOperation] Need to fetch photo asset")
            if let asset = file.getPHAsset(),
               let url = photoLibraryUploader.getUrlSync(for: asset) {
                ABLog("[UploadOperation] Got photo asset, writing URL")
                file.pathURL = url
            } else {
                ABLog("[UploadOperation] Failed to get photo asset", level: .error)
            }
        }
    }

    // MARK: Legacy
    
    // called on restoration
    func uploadCompletion(data: Data?, response: URLResponse?, error: Error?) {
        completionLock.wait()
        // Task has called end() in backgroundTaskExpired
        guard !isFinished else { return }
        completionLock.enter()

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        if let error = error {
            // Client-side error
            ABLog("[UploadOperation] Client-side error for job \(file.id): \(error)", level: .error)
            if file.error != .taskRescheduled {
                file.sessionUrl = ""
            } else {
                // We return because we don't want end() to be called as it is already called in the expiration handler
                completionLock.leave()
                return
            }
            if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                if file.error != .taskExpirationCancelled && file.error != .taskRescheduled {
                    file.error = .taskCancelled
                    file.maxRetryCount = 0
                }
            } else {
                file.error = .networkError
            }
        } else if let data = data,
                  let response = try? ApiFetcher.decoder.decode(ApiResponse<[File]>.self, from: data),
                  let driveFile = response.data?.first {
            // Success
            ABLog("[UploadOperation] Job \(file.id) successful")
            file.uploadDate = Date()
            file.error = nil
            if let driveFileManager = accountManager.getDriveFileManager(for: file.driveId, userId: file.userId) {
                // File is already or has parent in DB let's update it
                let queue = BackgroundRealm.getQueue(for: driveFileManager.realmConfiguration)
                queue.execute { realm in
                    if driveFileManager.getCachedFile(id: driveFile.id, freeze: false, using: realm) != nil || file.relativePath.isEmpty {
                        if let oldFile = realm.object(ofType: File.self, forPrimaryKey: driveFile.id), oldFile.isAvailableOffline {
                            driveFile.isAvailableOffline = true
                        }
                        let parent = driveFileManager.getCachedFile(id: file.parentDirectoryId, freeze: false, using: realm)
                        queue.bufferedWrite(in: parent, file: driveFile)
                        result.driveFile = File(value: driveFile)
                    }
                }
            }
        } else {
            // Server-side error
            var error = DriveError.serverError
            if let data = data,
               let apiError = try? ApiFetcher.decoder.decode(ApiResponse<Empty>.self, from: data).error {
                error = DriveError(apiError: apiError)
            }
            ABLog("[UploadOperation] Server error for job \(file.id) (code: \(statusCode)): \(error)", level: .error)
            file.sessionUrl = ""
            file.error = error
            if error == .quotaExceeded {
                file.maxRetryCount = 0
            } else if error == .objectNotFound {
                // If we get an ”object not found“ error, we cancel all further uploads in this folder
                file.maxRetryCount = 0
                uploadQueue.cancelAllOperations(withParent: file.parentDirectoryId, userId: file.userId, driveId: file.driveId)
                if photoLibraryUploader.isSyncEnabled && photoLibraryUploader.settings?.parentDirectoryId == file.parentDirectoryId {
                    photoLibraryUploader.disableSync()
                    NotificationsHelper.sendPhotoSyncErrorNotification()
                }
            }
        }

        end()
        completionLock.leave()
    }

    // over 30sec
    private func backgroundTaskExpired() {
        completionLock.wait()
        // Task has called end() in uploadCompletion
        guard !isFinished else { return }
        completionLock.enter()

        ABLog("[UploadOperation] Background task expired")
        let breadcrumb = Breadcrumb(level: .info, category: "BackgroundUploadTask")
        breadcrumb.message = "Rescheduling file \(file.name)"
        breadcrumb.data = ["File id": file.id,
                           "File name": file.name,
                           "File size": file.size,
                           "File type": file.type.rawValue]
        SentrySDK.addBreadcrumb(crumb: breadcrumb)
        
        // reschedule
            // is within session upload windows ?
            // ? invalid chunks ?
            // ? retry count ?
        
        
        // TODO: Ouroboros something something…
//        let rescheduledSessionId = backgroundUploadManager.rescheduleForBackground(task: task, fileUrl: file.pathURL)
//        if let sessionId = rescheduledSessionId {
//            file.sessionId = sessionId
//            file.error = .taskRescheduled
//        } else {
//            file.sessionUrl = ""
//            file.error = .taskExpirationCancelled
//            uploadNotifiable.sendPausedNotificationIfNeeded()
//        }
        uploadQueue.suspendAllOperations()
        
        // task?.cancel()
        for (key, value) in uploadTasks {
            value.cancel()
        }
        
        end()
        completionLock.leave()
        ABLog("[UploadOperation] Expiration handler end block job \(file.id)")
    }

    // did finish in time
    private func end() {
        if let error = file.error {
            ABLog("[UploadOperation] Job \(file.id) errorCode: \(error.code) error:\(error)", level: .error)
        } else {
            ABLog("[UploadOperation] Job \(file.id)")
        }

        if let path = file.pathURL,
           file.shouldRemoveAfterUpload && (file.error == nil || file.error == .taskCancelled) {
            try? FileManager.default.removeItem(at: path)
        }

        // Save upload file
        result.uploadFile = UploadFile(value: file)
        if file.error != .taskCancelled {
            BackgroundRealm.uploads.execute { uploadsRealm in
                try? uploadsRealm.safeWrite {
                    uploadsRealm.add(UploadFile(value: file), update: .modified)
                }
            }
        } else {
            BackgroundRealm.uploads.execute { uploadsRealm in
                if let toDelete = uploadsRealm.object(ofType: UploadFile.self, forPrimaryKey: file.id) {
                    try? uploadsRealm.safeWrite {
                        uploadsRealm.delete(toDelete)
                    }
                }
            }
        }

        progressObservation?.invalidate()
        if backgroundTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        }

        // Terminate the NSOperation
        ABLog("[UploadOperation] Job \(file.id) operation terminated")
        finish()
    }
}
