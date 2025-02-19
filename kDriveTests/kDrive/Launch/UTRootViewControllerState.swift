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

import InfomaniakCore
import InfomaniakCoreUI
@testable import InfomaniakDI
import InfomaniakLogin
@testable import kDrive
@testable import kDriveCore
import RealmSwift
import XCTest

final class UTRootViewControllerState: XCTestCase {
    let fakeAccount = Account(apiToken: ApiToken(
        accessToken: "",
        expiresIn: 0,
        refreshToken: "",
        scope: "",
        tokenType: "",
        userId: 0,
        expirationDate: Date()
    ))

    override func setUpWithError() throws {
        SimpleResolver.sharedResolver.removeAll()

        let services = [
            Factory(type: InfomaniakNetworkLogin.self) { _, _ in
                InfomaniakNetworkLogin(clientId: "", redirectUri: "")
            },
            Factory(type: UploadQueue.self) { _, _ in
                UploadQueue()
            },
            Factory(type: UploadQueueable.self) { _, resolver in
                try resolver.resolve(type: UploadQueue.self,
                                     forCustomTypeIdentifier: nil,
                                     factoryParameters: nil,
                                     resolver: resolver)
            },
            Factory(type: InfomaniakNetworkLoginable.self) { _, resolver in
                try resolver.resolve(type: InfomaniakNetworkLogin.self,
                                     forCustomTypeIdentifier: nil,
                                     factoryParameters: nil,
                                     resolver: resolver)
            },
            Factory(type: InfomaniakTokenable.self) { _, resolver in
                try resolver.resolve(type: InfomaniakLoginable.self,
                                     forCustomTypeIdentifier: nil,
                                     factoryParameters: nil,
                                     resolver: resolver)
            },
            Factory(type: InfomaniakLoginable.self) { _, _ in
                InfomaniakLogin(clientId: DriveApiFetcher.clientId)
            },
            Factory(type: AppLockHelper.self) { _, _ in
                AppLockHelper()
            }
        ]
        services.forEach {
            SimpleResolver.sharedResolver.store(factory: $0)
        }
    }

    func testFirstLaunchState() throws {
        // GIVEN empty accounts
        UserDefaults.shared.isAppLockEnabled = false
        UserDefaults.shared.legacyIsFirstLaunch = true

        let emptyAccountManagerFactory = Factory(type: AccountManageable.self) { _, _ in
            let accountManager = MockAccountManager()
            return accountManager
        }
        SimpleResolver.sharedResolver.store(factory: emptyAccountManagerFactory)

        // WHEN
        let currentState = RootViewControllerState.getCurrentState()

        // THEN
        XCTAssertEqual(currentState, .onboarding, "State should be onboarding")
    }

    func testOnboardingState() throws {
        // GIVEN empty accounts
        UserDefaults.shared.isAppLockEnabled = false
        UserDefaults.shared.legacyIsFirstLaunch = false

        let emptyAccountManagerFactory = Factory(type: AccountManageable.self) { _, _ in
            let accountManager = MockAccountManager()
            return accountManager
        }
        SimpleResolver.sharedResolver.store(factory: emptyAccountManagerFactory)

        // WHEN
        let currentState = RootViewControllerState.getCurrentState()

        // THEN
        XCTAssertEqual(currentState, .onboarding, "State should be onboarding")
    }

    func testOnboardingWithAppLockState() throws {
        // GIVEN empty accounts BUT AppLock enabled
        UserDefaults.shared.isAppLockEnabled = true
        UserDefaults.shared.legacyIsFirstLaunch = false

        let emptyAccountManagerFactory = Factory(type: AccountManageable.self) { _, _ in
            let accountManager = MockAccountManager()
            return accountManager
        }
        SimpleResolver.sharedResolver.store(factory: emptyAccountManagerFactory)

        // WHEN
        let currentState = RootViewControllerState.getCurrentState()

        // THEN
        XCTAssertEqual(currentState, .onboarding, "State should be onboarding")
    }

    func testAppLockState() throws {
        // GIVEN
        UserDefaults.shared.isAppLockEnabled = true
        UserDefaults.shared.legacyIsFirstLaunch = false

        let emptyAccountManagerFactory = Factory(type: AccountManageable.self) { _, _ in
            let accountManager = MockAccountManager()
            accountManager.accounts = [self.fakeAccount]
            return accountManager
        }
        SimpleResolver.sharedResolver.store(factory: emptyAccountManagerFactory)

        // WHEN
        let currentState = RootViewControllerState.getCurrentState()

        // THEN
        XCTAssertEqual(currentState, .appLock, "State should be applock")
    }

    func testNoDriveFileManagerState() throws {
        // GIVEN
        UserDefaults.shared.isAppLockEnabled = false
        UserDefaults.shared.legacyIsFirstLaunch = false

        let emptyAccountManagerFactory = Factory(type: AccountManageable.self) { _, _ in
            let accountManager = MockAccountManager()
            accountManager.accounts = [self.fakeAccount]
            return accountManager
        }
        SimpleResolver.sharedResolver.store(factory: emptyAccountManagerFactory)

        // WHEN
        let currentState = RootViewControllerState.getCurrentState()

        // THEN
        XCTAssertEqual(currentState, .onboarding, "State should be onboarding")
    }

    func testMainViewControllerState() throws {
        // GIVEN
        UserDefaults.shared.isAppLockEnabled = false
        UserDefaults.shared.legacyIsFirstLaunch = false

        let accountManagerFactory = Factory(type: AccountManageable.self) { _, _ in
            let accountManager = MockAccountManager()
            accountManager.accounts = [self.fakeAccount]
            accountManager.currentDriveFileManager = DriveFileManager(
                drive: Drive(),
                apiFetcher: DriveApiFetcher(token: self.fakeAccount.token, delegate: accountManager)
            )
            return accountManager
        }
        SimpleResolver.sharedResolver.store(factory: accountManagerFactory)

        // WHEN
        let currentState = RootViewControllerState.getCurrentState()

        // THEN
        @InjectService var accountManager: AccountManageable
        XCTAssertEqual(currentState, .mainViewController(accountManager.currentDriveFileManager!), "State should be mainview")
    }
}

extension RootViewControllerState: Equatable {
    public static func == (lhs: RootViewControllerState, rhs: RootViewControllerState) -> Bool {
        switch (lhs, rhs) {
        case (.appLock, .appLock):
            return true
        case (.onboarding, .onboarding):
            return true
        case (.mainViewController(let lhsMailboxManager), .mainViewController(let rhsMailboxManager)):
            return lhsMailboxManager.drive.objectId == rhsMailboxManager.drive.objectId
        default:
            return false
        }
    }
}
