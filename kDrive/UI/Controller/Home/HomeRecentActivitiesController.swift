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
import kDriveCore

class HomeRecentActivitiesController: HomeRecentFilesController {
    private let mergeFileCreateDelay = 43_200 // 12h

    required convenience init(driveFileManager: DriveFileManager, homeViewController: HomeViewController) {
        self.init(driveFileManager: driveFileManager,
                  homeViewController: homeViewController,
                  listCellType: RecentActivityCollectionViewCell.self, gridCellType: RecentActivityCollectionViewCell.self, emptyCellType: .noActivities,
                  title: KDriveStrings.Localizable.lastEditsTitle, selectorTitle: KDriveStrings.Localizable.fileDetailsActivitiesTitle,
                  listStyleEnabled: false)
    }

    override func loadNextPage(forceRefresh: Bool = false) {
        guard !loading && moreComing else {
            return
        }
        loading = true

        driveFileManager.apiFetcher.getRecentActivity(driveId: driveFileManager.drive.id, page: page) { response, _ in
            self.loading = false
            if let activities = response?.data {
                self.empty = self.page == 1 && activities.isEmpty
                self.moreComing = activities.count == DriveApiFetcher.itemPerPage
                self.page += 1

                DispatchQueue.global(qos: .utility).async {
                    let mergedActivities = self.mergeAndClean(activities: activities)
                    DispatchQueue.main.async {
                        self.homeViewController?.reloadWith(fetchedActivities: mergedActivities, isEmpty: self.empty)
                    }
                }
                // Update cache
                if self.page == 1 {
                    self.driveFileManager.setLocalRecentActivities(activities)
                }
            } else {
                DispatchQueue.global(qos: .utility).async {
                    let activities = self.driveFileManager.getLocalRecentActivities()
                    let mergedActivities = self.mergeAndClean(activities: activities)

                    self.empty = mergedActivities.isEmpty
                    self.moreComing = false
                    DispatchQueue.main.async {
                        self.homeViewController?.reloadWith(fetchedActivities: mergedActivities, isEmpty: self.empty)
                    }
                }
            }
        }
    }

    private func mergeAndClean(activities: [FileActivity]) -> [FileActivity] {
        let activities = activities.filter { $0.user != nil }

        var resultActivities = [FileActivity]()
        var ignoredActivityIds = [Int]()

        for (index, activity) in activities.enumerated() {
            let ignoreActivity = !resultActivities.isEmpty && resultActivities.last?.user?.id == activity.user?.id && resultActivities.last?.action == activity.action && resultActivities.last?.file?.id == activity.file?.id
            if !ignoredActivityIds.contains(activity.id) && !ignoreActivity {
                var i = index + 1
                var mergedFilesTemp = [activity.fileId: activity.file]
                while i < activities.count && activity.createdAt - activities[i].createdAt <= mergeFileCreateDelay {
                    if activity.user?.id == activities[i].user?.id && activity.action == activities[i].action && activity.file?.type == activities[i].file?.type {
                        ignoredActivityIds.append(activities[i].id)
                        if mergedFilesTemp[activities[i].fileId] == nil {
                            activity.mergedFileActivities.append(activities[i])
                            mergedFilesTemp[activities[i].fileId] = activities[i].file
                        }
                    }
                    i += 1
                }
                resultActivities.append(activity)
            }
        }

        return resultActivities
    }

    private func loadLocalRecentActivities(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let activities = self.driveFileManager.getLocalRecentActivities()
            // self.recentActivities = self.mergeAndClean(activities: activities)
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    override func getLayout(for style: ListStyle) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(200))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        group.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 16
        section.boundarySupplementaryItems = [getHeaderLayout()]
        return section
    }

    override class func initInstance(driveFileManager: DriveFileManager, homeViewController: HomeViewController) -> Self {
        return Self(driveFileManager: driveFileManager, homeViewController: homeViewController)
    }
}
