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
import CocoaLumberjackSwift

public protocol FileDownloadSession {
    func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask
}

extension URLSession: FileDownloadSession { }

public class BackgroundDownloadSessionManager: NSObject, URLSessionDownloadDelegate, FileDownloadSession {

    public typealias CompletionHandler = (URL?, URLResponse?, Error?) -> Void
    static let maxBackgroundTasks = 10
    public static var instance = BackgroundDownloadSessionManager()

    public var backgroundCompletionHandler: (() -> Void)?
    public var backgroundTaskCount: Int {
        return operations.count
    }

    private var backgroundDownloadSession: URLSession!
    private var tasksCompletionHandler: [Int: CompletionHandler] = [:]
    private var progressObservers: [Int: NSKeyValueObservation] = [:]
    private var operations = [DownloadOperation]()

    private override init() {
        super.init()
        let backgroundUrlSessionConfiguration = URLSessionConfiguration.background(withIdentifier: DownloadQueue.downloadQueueIdentifier)
        backgroundUrlSessionConfiguration.sessionSendsLaunchEvents = true
        backgroundUrlSessionConfiguration.shouldUseExtendedBackgroundIdleMode = true
        backgroundUrlSessionConfiguration.sharedContainerIdentifier = AccountManager.appGroup
        backgroundDownloadSession = URLSession(configuration: backgroundUrlSessionConfiguration, delegate: self, delegateQueue: nil)
    }

    public func reconnectBackgroundTasks() {
        backgroundDownloadSession.getTasksWithCompletionHandler { (_, uploadTasks, _) in
            let realm = DriveFileManager.constants.uploadsRealm
            for task in uploadTasks {
                if let sessionUrl = task.originalRequest?.url?.absoluteString,
                    let fileId = realm.objects(DownloadTask.self).filter(NSPredicate(format: "AND sessionUrl = %@", sessionUrl)).first?.fileId {
                    self.progressObservers[task.taskIdentifier] = task.progress.observe(\.fractionCompleted, options: .new, changeHandler: { [fileId = fileId] (progress, value) in
                        guard let newValue = value.newValue else {
                            return
                        }
                        DownloadQueue2.instance.publishProgress(newValue, for: fileId)
                    })
                }
            }
        }
    }

    public func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        let task = backgroundDownloadSession.downloadTask(with: request)
        tasksCompletionHandler[task.taskIdentifier] = completionHandler
        return task
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Unsuccessful completion
        if let task = task as? URLSessionDownloadTask {
            getCompletionHandler(for: task)?(nil, task.response, error)
        }
        progressObservers[task.taskIdentifier]?.invalidate()
        progressObservers[task.taskIdentifier] = nil
        tasksCompletionHandler[task.taskIdentifier] = nil
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Successful completion
        getCompletionHandler(for: downloadTask)?(location, downloadTask.response, nil)
        progressObservers[downloadTask.taskIdentifier]?.invalidate()
        progressObservers[downloadTask.taskIdentifier] = nil
        tasksCompletionHandler[downloadTask.taskIdentifier] = nil
    }

    func getCompletionHandler(for task: URLSessionDownloadTask) -> CompletionHandler? {
        if let completionHandler = tasksCompletionHandler[task.taskIdentifier] {
            return completionHandler
        } else if let sessionUrl = task.originalRequest?.url?.absoluteString,
            let downloadTask = DriveFileManager.constants.uploadsRealm.objects(DownloadTask.self)
            .filter(NSPredicate(format: "sessionUrl = %@", sessionUrl)).first,
            let drive = AccountManager.instance.getDrive(for: downloadTask.userId, driveId: downloadTask.driveId),
            let driveFileManager = AccountManager.instance.getDriveFileManager(for: drive),
            let file = driveFileManager.getCachedFile(id: downloadTask.fileId) {
            let operation = DownloadOperation(file: file, driveFileManager: driveFileManager, task: task, urlSession: self)
            tasksCompletionHandler[task.taskIdentifier] = operation.downloadCompletion
            operations.append(operation)
            return operation.downloadCompletion
        } else {
            return nil
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
