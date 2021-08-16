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

import Atlantis
import AVFoundation
import BackgroundTasks
import CocoaLumberjackSwift
import Firebase
import InfomaniakCore
import InfomaniakLogin
import kDriveCore
import Kingfisher
import Sentry
import StoreKit
import UIKit
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, AccountManagerDelegate {
    var window: UIWindow?

    private var accountManager: AccountManager!
    private var uploadQueue: UploadQueue!
    private var reachabilityListener: ReachabilityListener!

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Logging.initLogging()
        DDLogInfo("Application starting in foreground ? \(UIApplication.shared.applicationState != .background)")
        ImageCache.default.memoryStorage.config.totalCostLimit = 20
        InfomaniakLogin.initWith(clientId: DriveApiFetcher.clientId)
        accountManager = AccountManager.instance
        uploadQueue = UploadQueue.instance
        reachabilityListener = ReachabilityListener.instance

        // Start audio session
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
        } catch {
            DDLogError("Error while setting playback audio category")
            SentrySDK.capture(error: error)
        }

        if #available(iOS 13.0, *) {
            registerBackgroundTasks()
        } else {
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }

        NotificationsHelper.askForPermissions()
        NotificationsHelper.registerCategories()
        UNUserNotificationCenter.current().delegate = self

        if UIApplication.shared.applicationState != .background {
            launchSetup()
        }

        if CommandLine.arguments.contains("testing") {
            UIView.setAnimationsEnabled(false)
        }

        if #available(iOS 13.0, *) {
            window?.overrideUserInterfaceStyle = UserDefaults.shared.theme.interfaceStyle
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleLocateUploadNotification), name: .locateUploadActionTapped, object: nil)

        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FirebaseApp.configure()

        // Register for remote notifications. This shows a permission dialog on first run, to
        // show the dialog at a more appropriate time move this registration accordingly.
        // [START register_for_notifications]
        // For iOS 10 display notification (sent via APNS)
        UNUserNotificationCenter.current().delegate = self
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions,
            completionHandler: { _, _ in }
        )
        application.registerForRemoteNotifications()
        Messaging.messaging().delegate = self

        if UserDefaults.shared.importNotificationsEnabled {
            Messaging.messaging().subscribe(toTopic: Constants.notificationTopicUpload)
        }
        if UserDefaults.shared.sharingNotificationsEnabled {
            Messaging.messaging().subscribe(toTopic: Constants.notificationTopicShared)
        }
        if UserDefaults.shared.newCommentNotificationsEnabled {
            Messaging.messaging().subscribe(toTopic: Constants.notificationTopicComments)
        }
        if UserDefaults.shared.generalNotificationEnabled {
            Messaging.messaging().subscribe(toTopic: Constants.notificationTopicGeneral)
        }

        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DDLogError("Unable to register for remote notifications: \(error.localizedDescription)")
    }

    @available(iOS 13.0, *)
    private func registerBackgroundTasks() {
        var registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Constants.backgroundRefreshIdentifier, using: nil) { task in
            self.scheduleBackgroundRefresh()

            task.expirationHandler = {
                UploadQueue.instance.suspendAllOperations()
                UploadQueue.instance.cancelRunningOperations()
                task.setTaskCompleted(success: false)
            }

            self.handleBackgroundRefresh { _ in
                task.setTaskCompleted(success: true)
            }
        }
        DDLogInfo("Task \(Constants.backgroundRefreshIdentifier) registered ? \(registered)")
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Constants.longBackgroundRefreshIdentifier, using: nil) { task in
            self.scheduleBackgroundRefresh()

            task.expirationHandler = {
                UploadQueue.instance.suspendAllOperations()
                UploadQueue.instance.cancelRunningOperations()
                task.setTaskCompleted(success: false)
            }

            self.handleBackgroundRefresh { _ in
                task.setTaskCompleted(success: true)
            }
        }
        DDLogInfo("Task \(Constants.longBackgroundRefreshIdentifier) registered ? \(registered)")
    }

    func handleBackgroundRefresh(completion: @escaping (Bool) -> Void) {
        // User installed the app but never logged in
        if accountManager.accounts.isEmpty {
            completion(false)
            return
        }

        _ = PhotoLibraryUploader.instance.addNewPicturesToUploadQueue()
        UploadQueue.instance.waitForCompletion {
            completion(true)
        }
    }

    @available(iOS 13.0, *)
    private func scheduleBackgroundRefresh() {
        let backgroundRefreshRequest = BGAppRefreshTaskRequest(identifier: Constants.backgroundRefreshIdentifier)
        backgroundRefreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

        let longBackgroundRefreshRequest = BGProcessingTaskRequest(identifier: Constants.longBackgroundRefreshIdentifier)
        longBackgroundRefreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        longBackgroundRefreshRequest.requiresNetworkConnectivity = true
        longBackgroundRefreshRequest.requiresExternalPower = true
        do {
            try BGTaskScheduler.shared.submit(backgroundRefreshRequest)
            try BGTaskScheduler.shared.submit(longBackgroundRefreshRequest)
        } catch {
            DDLogError("Error scheduling background task: \(error)")
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        if #available(iOS 13.0, *) {
            /* To debug background tasks:
              Launch ->
              e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.infomaniak.background.refresh"]
              Force early termination ->
              e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.infomaniak.background.refresh"]
             */
            scheduleBackgroundRefresh()
        }
        if UserDefaults.shared.isAppLockEnabled && !(window?.rootViewController?.isKind(of: LockedAppViewController.self) ?? false) {
            AppLockHelper.shared.setTime()
        }
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Old Nextcloud based app only supports this way for background fetch so it's the only place it will be called in the background.
        if MigrationHelper.canMigrate() {
            NotificationsHelper.sendMigrateNotification()
            return
        }

        handleBackgroundRefresh { newData in
            if newData {
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        }
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if url.isFileURL, let currentDriveFileManager = accountManager.currentDriveFileManager {
            let filename = url.lastPathComponent
            let importPath = DriveFileManager.constants.importDirectoryURL.appendingPathComponent(filename)
            do {
                if FileManager.default.fileExists(atPath: importPath.path) {
                    try FileManager.default.removeItem(atPath: importPath.path)
                }
                try FileManager.default.moveItem(at: url, to: importPath)
                let saveNavigationViewController = SaveFileViewController.instantiateInNavigationController(driveFileManager: currentDriveFileManager, file: .init(name: filename, path: importPath, uti: importPath.uti ?? .data))
                window?.rootViewController?.present(saveNavigationViewController, animated: true)
                return true
            } catch {
                return false
            }
        } else {
            return false
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        UploadQueue.instance.pausedNotificationSent = false
        launchSetup()
    }

    private func launchSetup() {
        // Set global tint color
        window?.tintColor = KDriveAsset.infomaniakColor.color
        UITabBar.appearance().unselectedItemTintColor = KDriveAsset.iconColor.color

        if MigrationHelper.canMigrate() && accountManager.accounts.isEmpty {
            window?.rootViewController = MigrationViewController.instantiate()
            window?.makeKeyAndVisible()
        } else if UserDefaults.isFirstLaunch() || accountManager.accounts.isEmpty {
            if !(window?.rootViewController?.isKind(of: OnboardingViewController.self) ?? false) {
                KeychainHelper.deleteAllTokens()
                window?.rootViewController = OnboardingViewController.instantiate()
                window?.makeKeyAndVisible()
            }
            // Clean File Provider domains on first launch in case we had some dangling
            DriveInfosManager.instance.deleteAllFileProviderDomains()
        } else if UserDefaults.shared.isAppLockEnabled && AppLockHelper.shared.isAppLocked {
            window?.rootViewController = LockedAppViewController.instantiate()
            window?.makeKeyAndVisible()
        } else {
            UserDefaults.shared.numberOfConnections += 1
            var appVersion = AppVersion()
            appVersion.loadVersionData { [self] version in
                appVersion.version = version.version
                appVersion.currentVersionReleaseDate = version.currentVersionReleaseDate

                if appVersion.showUpdateFloatingPanel() {
                    if !UserDefaults.shared.updateLater || UserDefaults.shared.numberOfConnections % 10 == 0 {
                        let floatingPanelViewController = UpdateFloatingPanelViewController.instantiatePanel()
                        (floatingPanelViewController.contentViewController as? UpdateFloatingPanelViewController)?.actionHandler = { _ in
                            if let url = URL(string: "https://apps.apple.com/app/infomaniak-kdrive/id1482778676") {
                                UserDefaults.shared.updateLater = false
                                UIApplication.shared.open(url)
                            }
                        }
                        self.window?.rootViewController?.present(floatingPanelViewController, animated: true)
                    }
                }
            }
            if let currentDriveFileManager = accountManager.currentDriveFileManager,
               UserDefaults.shared.numberOfConnections == 1 && !PhotoLibraryUploader.instance.isSyncEnabled {
                let floatingPanelViewController = SavePhotosFloatingPanelViewController.instantiatePanel(drive: currentDriveFileManager.drive)
                let savePhotosFloatingPanelViewController = (floatingPanelViewController.contentViewController as? SavePhotosFloatingPanelViewController)
                savePhotosFloatingPanelViewController?.actionHandler = { [self] _ in
                    let photoSyncSettingsVC = PhotoSyncSettingsViewController.instantiate()
                    photoSyncSettingsVC.driveFileManager = currentDriveFileManager
                    let mainTabViewVC = self.window?.rootViewController as? UITabBarController
                    guard let currentVC = mainTabViewVC?.selectedViewController as? UINavigationController else {
                        return
                    }
                    currentVC.dismiss(animated: true)
                    currentVC.setInfomaniakAppearanceNavigationBar()
                    currentVC.pushViewController(photoSyncSettingsVC, animated: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.window?.rootViewController?.present(floatingPanelViewController, animated: true)
                }
            }
            if UserDefaults.shared.numberOfConnections == 10 {
                if #available(iOS 14.0, *) {
                    if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                        SKStoreReviewController.requestReview(in: scene)
                    }
                } else {
                    SKStoreReviewController.requestReview()
                }
            }
            if !UserDefaults.shared.betaInviteDisplayed && !Bundle.main.isRunningInTestFlight {
                let floatingPanelViewController = BetaInviteFloatingPanelViewController.instantiatePanel()
                (floatingPanelViewController.contentViewController as? BetaInviteFloatingPanelViewController)?.actionHandler = { _ in
                    if let url = URL(string: "https://testflight.apple.com/join/qZHSGy5B") {
                        UserDefaults.shared.betaInviteDisplayed = true
                        UIApplication.shared.open(url)
                        floatingPanelViewController.dismiss(animated: true)
                    }
                }
                DispatchQueue.main.async {
                    self.window?.rootViewController?.present(floatingPanelViewController, animated: true)
                }
            }
            refreshCacheData(preload: false, isSwitching: false)
            uploadEditedFiles()
            // Ask to remove uploaded pictures
            if let toRemoveItems = PhotoLibraryUploader.instance.getPicturesToRemove() {
                let alert = AlertTextViewController(title: KDriveStrings.Localizable.modalDeletePhotosTitle, message: KDriveStrings.Localizable.modalDeletePhotosDescription, action: KDriveStrings.Localizable.buttonDelete, destructive: true, loading: false) {
                    // Proceed with removal
                    PhotoLibraryUploader.instance.removePicturesFromPhotoLibrary(toRemoveItems)
                }
                DispatchQueue.main.async {
                    self.window?.rootViewController?.present(alert, animated: true)
                }
            }
        }
    }

    func refreshCacheData(preload: Bool, isSwitching: Bool) {
        let currentAccount = AccountManager.instance.currentAccount!
        let rootViewController = window?.rootViewController as? SwitchAccountDelegate

        if preload {
            DispatchQueue.main.async {
                if isSwitching {
                    rootViewController?.didSwitchCurrentAccount(currentAccount)
                } else {
                    rootViewController?.didUpdateCurrentAccountInformations(currentAccount)
                }
            }
            updateAvailableOfflineFiles(status: ReachabilityListener.instance.currentStatus)
        } else {
            var token: ObservationToken?
            token = ReachabilityListener.instance.observeNetworkChange(self) { [unowned self] status in
                updateAvailableOfflineFiles(status: status)
                // Remove observer after 1 pass
                token?.cancel()
            }
        }

        accountManager.updateUserForAccount(currentAccount, registerToken: true) { [self] _, switchedDrive, error in
            if let error = error {
                UIConstants.showSnackBar(message: KDriveStrings.Localizable.errorGeneric)
                DDLogError("Error while updating user account: \(error)")
            } else {
                if isSwitching {
                    rootViewController?.didSwitchCurrentAccount(currentAccount)
                } else {
                    rootViewController?.didUpdateCurrentAccountInformations(currentAccount)
                }
                if let drive = switchedDrive,
                   let driveFileManager = accountManager.getDriveFileManager(for: drive),
                   !drive.maintenance {
                    (rootViewController as? SwitchDriveDelegate)?.didSwitchDriveFileManager(newDriveFileManager: driveFileManager)
                }

                if let currentDrive = accountManager.getDrive(for: accountManager.currentUserId, driveId: accountManager.currentDriveId),
                   currentDrive.maintenance {
                    if let nextAvailableDrive = DriveInfosManager.instance.getDrives(for: currentAccount.userId).first(where: { !$0.maintenance }),
                       let driveFileManager = accountManager.getDriveFileManager(for: nextAvailableDrive) {
                        accountManager.setCurrentDriveForCurrentAccount(drive: nextAvailableDrive)
                        (rootViewController as? SwitchDriveDelegate)?.didSwitchDriveFileManager(newDriveFileManager: driveFileManager)
                    } else {
                        let driveErrorViewControllerNav = DriveErrorViewController.instantiateInNavigationController()
                        let driveErrorViewController = driveErrorViewControllerNav.viewControllers.first as? DriveErrorViewController
                        driveErrorViewController?.driveErrorViewType = .maintenance
                        if DriveInfosManager.instance.getDrives(for: currentAccount.userId).count == 1 {
                            driveErrorViewController?.driveName = currentDrive.name
                        }
                        setRootViewController(driveErrorViewControllerNav)
                    }
                }

                UploadQueue.instance.resumeAllOperations()
                UploadQueue.instance.addToQueueFromRealm()
                BackgroundUploadSessionManager.instance.reconnectBackgroundTasks()
                DispatchQueue.global(qos: .utility).async {
                    _ = PhotoLibraryUploader.instance.addNewPicturesToUploadQueue()
                }
            }
        }
    }

    private func uploadEditedFiles() {
        guard let folderURL = DriveFileManager.constants.openInPlaceDirectoryURL, FileManager.default.fileExists(atPath: folderURL.path) else { return }
        let group = DispatchGroup()
        var shouldCleanFolder = false
        let driveFolders = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        // Hierarchy inside folderURL should be /driveId/fileId/fileName.extension
        for driveFolder in driveFolders {
            // Read drive folder
            let driveFolderURL = folderURL.appendingPathComponent(driveFolder)
            guard let driveId = Int(driveFolder),
                  let drive = DriveInfosManager.instance.getDrive(id: driveId, userId: accountManager.currentUserId),
                  let fileFolders = try? FileManager.default.contentsOfDirectory(atPath: driveFolderURL.path) else {
                DDLogInfo("[OPEN-IN-PLACE UPLOAD] Could not infer drive from \(driveFolderURL)")
                continue
            }
            for fileFolder in fileFolders {
                // Read file folder
                let fileFolderURL = driveFolderURL.appendingPathComponent(fileFolder)
                guard let fileId = Int(fileFolder),
                      let driveFileManager = accountManager.getDriveFileManager(for: drive),
                      let file = driveFileManager.getCachedFile(id: fileId) else {
                    DDLogInfo("[OPEN-IN-PLACE UPLOAD] Could not infer file from \(fileFolderURL)")
                    continue
                }
                let fileURL = fileFolderURL.appendingPathComponent(file.name)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    // Compare modification date
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let modificationDate = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
                    if modificationDate > file.lastModifiedDate {
                        // Copy and upload file
                        let uploadFile = UploadFile(parentDirectoryId: file.parentId,
                                                    userId: accountManager.currentUserId,
                                                    driveId: driveId,
                                                    url: fileURL,
                                                    name: file.name,
                                                    shouldRemoveAfterUpload: false)
                        group.enter()
                        shouldCleanFolder = true
                        uploadQueue.observeFileUploaded(self, fileId: uploadFile.id) { [fileId = file.id] uploadFile, _ in
                            if let error = uploadFile.error {
                                shouldCleanFolder = false
                                DDLogError("[OPEN-IN-PLACE UPLOAD] Error while uploading: \(error)")
                            } else {
                                // Update file to get the new modification date
                                driveFileManager.getFile(id: fileId, forceRefresh: true) { file, _, _ in
                                    if let file = file {
                                        driveFileManager.notifyObserversWith(file: file)
                                    }
                                }
                            }
                            group.leave()
                        }
                        uploadQueue.addToQueue(file: uploadFile)
                    }
                }
            }
        }
        // Clean folder after completing all uploads
        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            if shouldCleanFolder {
                DDLogInfo("[OPEN-IN-PLACE UPLOAD] Cleaning folder")
                try? FileManager.default.removeItem(at: folderURL)
            }
        }
    }

    func updateAvailableOfflineFiles(status: ReachabilityListener.NetworkStatus) {
        guard status != .offline && (!UserDefaults.shared.isWifiOnly || status == .wifi) else {
            return
        }

        for drive in DriveInfosManager.instance.getDrives(for: accountManager.currentUserId, sharedWithMe: false) {
            guard let driveFileManager = accountManager.getDriveFileManager(for: drive) else {
                continue
            }

            let offlineFiles = driveFileManager.getAvailableOfflineFiles()
            guard !offlineFiles.isEmpty else { continue }
            driveFileManager.getFilesActivities(driveId: drive.id, files: offlineFiles, from: UserDefaults.shared.lastSyncDateOfflineFiles) { result in
                switch result {
                case .success(let filesActivities):
                    for (fileId, content) in filesActivities {
                        guard let file = offlineFiles.first(where: { $0.id == fileId }) else {
                            continue
                        }

                        if let activities = content.activities {
                            // Apply activities to file
                            var handledActivities = Set<FileActivityType>()
                            for activity in activities where !handledActivities.contains(activity.action) {
                                switch activity.action {
                                case .fileRename:
                                    // Rename file
                                    driveFileManager.getFile(id: file.id, withExtras: true) { newFile, _, _ in
                                        if let newFile = newFile {
                                            try? driveFileManager.renameCachedFile(updatedFile: newFile, oldFile: file)
                                        }
                                    }
                                case .fileUpdate:
                                    // Download new version
                                    DownloadQueue.instance.addToQueue(file: file, userId: driveFileManager.drive.userId)
                                case .fileDelete:
                                    // File has been deleted -- remove it from offline files
                                    driveFileManager.setFileAvailableOffline(file: file, available: false) { _ in }
                                default:
                                    break
                                }
                                handledActivities.insert(activity.action)
                            }
                        } else if let error = content.error {
                            if DriveError(apiError: error) == .objectNotFound {
                                driveFileManager.setFileAvailableOffline(file: file, available: false) { _ in }
                            } else {
                                SentrySDK.capture(error: error)
                            }
                            // Silently handle error
                            DDLogError("Error while fetching [\(file.id) - \(file.name)] in [\(drive.id) - \(drive.name)]: \(error)")
                        }
                    }
                case .failure(let error):
                    // Silently handle error
                    DDLogError("Error while fetching offline files activities in [\(drive.id) - \(drive.name)]: \(error)")
                }
            }
        }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DDLogInfo("[Background Session] background session relaunched \(identifier)")
        if identifier == DownloadQueue.backgroundIdentifier {
            BackgroundDownloadSessionManager.instance.backgroundCompletionHandler = completionHandler
        } else if identifier.hasSuffix(UploadQueue.backgroundBaseIdentifier) {
            BackgroundUploadSessionManager.instance.handleEventsForBackgroundURLSession(identifier: identifier, completionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        return InfomaniakLogin.handleRedirectUri(url: url)
    }

    func setRootViewController(_ vc: UIViewController, animated: Bool = true) {
        guard animated, let window = self.window else {
            self.window?.rootViewController = vc
            self.window?.makeKeyAndVisible()
            return
        }

        window.rootViewController = vc
        window.makeKeyAndVisible()
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: nil, completion: nil)
    }

    func present(file: File, driveFileManager: DriveFileManager) {
        guard let rootViewController = window?.rootViewController as? MainTabViewController else {
            return
        }

        // Dismiss all view controllers presented
        rootViewController.dismiss(animated: false)
        // Select Files tab
        rootViewController.selectedIndex = 1

        guard let navController = rootViewController.selectedViewController as? UINavigationController,
              let viewController = navController.topViewController as? FileListViewController else {
            return
        }

        if !file.isRoot && viewController.currentDirectory?.id != file.id {
            // Pop to root
            navController.popToRootViewController(animated: false)
            // Present file
            let filePresenter = FilePresenter(viewController: viewController, floatingPanelViewController: nil)
            filePresenter.present(driveFileManager: driveFileManager, file: file, files: [file], normalFolderHierarchy: false)
        }
    }

    @objc func handleLocateUploadNotification(_ notification: Notification) {
        if let parentId = notification.userInfo?["parentId"] as? Int,
           let driveFileManager = accountManager.currentDriveFileManager,
           let folder = driveFileManager.getCachedFile(id: parentId) {
            present(file: folder, driveFileManager: driveFileManager)
        }
    }

    // MARK: - Account manager delegate

    func currentAccountNeedsAuthentication() {
        setRootViewController(SwitchUserViewController.instantiateInNavigationController())
    }

    // MARK: - State restoration

    func application(_ application: UIApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        return true
    }

    func application(_ application: UIApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        return !(UserDefaults.isFirstLaunch() || accountManager.accounts.isEmpty)
    }
}

// MARK: - User notification center delegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    // In Foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        _ = notification.request.content.userInfo

        // Change this to your preferred presentation option
        completionHandler([.alert, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        switch response.notification.request.trigger {
        case is UNPushNotificationTrigger:
            processPushNotification(response.notification)
        default:
            if response.notification.request.content.categoryIdentifier == NotificationsHelper.uploadCategoryId {
                // Upload notification
                let parentId = userInfo[NotificationsHelper.parentIdKey] as? Int

                switch response.actionIdentifier {
                case UNNotificationDefaultActionIdentifier:
                    // Notification tapped: open parent folder
                    if let parentId = parentId,
                       let driveFileManager = accountManager.currentDriveFileManager,
                       let folder = driveFileManager.getCachedFile(id: parentId) {
                        present(file: folder, driveFileManager: driveFileManager)
                    }
                default:
                    break
                }
            } else {
                // Handle other notification types...
            }
        }

        completionHandler()
    }

    private func processPushNotification(_ notification: UNNotification) {
        UIApplication.shared.applicationIconBadgeNumber = 0
//        PROCESS NOTIFICATION
//        let userInfo = notification.request.content.userInfo
//
//        let parentId = Int(userInfo["parentId"] as? String ?? "")
//        if let parentId = parentId,
//           let driveFileManager = accountManager.currentDriveFileManager,
//           let folder = driveFileManager.getCachedFile(id: parentId) {
//            present(file: folder, driveFileManager: driveFileManager)
//        }
//
//        Messaging.messaging().appDidReceiveMessage(userInfo)
    }
}

// MARK: - MessagingDelegate

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        let dataDict = ["token": fcmToken ?? ""]
        NotificationCenter.default.post(name: Notification.Name("FCMToken"), object: nil, userInfo: dataDict)
    }
}
