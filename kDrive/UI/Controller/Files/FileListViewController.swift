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

import CocoaLumberjackSwift
import DifferenceKit
import kDriveCore
import kDriveResources
import UIKit

extension SwipeCellAction {
    static let share = SwipeCellAction(identifier: "share", title: KDriveResourcesStrings.Localizable.buttonFileRights, backgroundColor: KDriveResourcesAsset.infomaniakColor.color, icon: KDriveResourcesAsset.share.image)
    static let delete = SwipeCellAction(identifier: "delete", title: KDriveResourcesStrings.Localizable.buttonDelete, backgroundColor: KDriveResourcesAsset.binColor.color, icon: KDriveResourcesAsset.delete.image)
}

extension SortType: Selectable {
    var title: String {
        return value.translation
    }
}

class FileListViewController: MultipleSelectionViewController, UICollectionViewDataSource, SwipeActionCollectionViewDelegate, SwipeActionCollectionViewDataSource, FilesHeaderViewDelegate {
    class var storyboard: UIStoryboard { Storyboard.files }
    class var storyboardIdentifier: String { "FileListViewController" }

    // MARK: - Constants

    private let leftRightInset = 12.0
    private let gridInnerSpacing = 16.0
    private let maxDiffChanges = Endpoint.itemsPerPage
    private let headerViewIdentifier = "FilesHeaderView"
    private let uploadCountThrottler = Throttler<Int>(timeInterval: 0.5, queue: .main)
    private let fileObserverThrottler = Throttler<File>(timeInterval: 5, queue: .global())

    // MARK: - Configuration

    struct Configuration {
        /// Is normal folder hierarchy
        var normalFolderHierarchy = true
        /// Enable or disable upload status displayed in the header (enabled by default)
        var showUploadingFiles = true
        /// Enable or disable multiple selection (enabled by default)
        var isMultipleSelectionEnabled = true
        /// Enable or disable refresh control (enabled by default)
        var isRefreshControlEnabled = true
        /// Is displayed from activities
        var fromActivities = false
        /// Does this folder support "select all" action (no effect if multiple selection is disabled)
        var selectAllSupported = true
        /// Root folder title
        var rootTitle: String?
        /// Type of empty view to display
        var emptyViewType: EmptyTableView.EmptyTableViewType
        /// Does this folder support importing files with drop from external app
        var supportsDrop = false
        /// Does this folder support importing files with drag from external app
        var supportDrag = true
    }

    // MARK: - Properties

    var collectionViewLayout: UICollectionViewFlowLayout!
    var refreshControl = UIRefreshControl()
    private var headerView: FilesHeaderView?
    private var floatingPanelViewController: DriveFloatingPanelController!
    #if !ISEXTENSION
        private var fileInformationsViewController: FileActionsFloatingPanelViewController!
    #endif
    private var loadingBarButtonItem: UIBarButtonItem = {
        let activityView = UIActivityIndicatorView(style: .medium)
        activityView.startAnimating()
        return UIBarButtonItem(customView: activityView)
    }()

    var currentDirectory: File! {
        didSet {
            setTitle()
        }
    }

    lazy var configuration = Configuration(emptyViewType: .emptyFolder, supportsDrop: true)
    private var uploadingFilesCount = 0
    private var nextPage = 1
    var isLoadingData = false
    private var isReloading = false
    private var isContentLoaded = false
    var listStyle = FileListOptions.instance.currentStyle {
        didSet {
            headerView?.listOrGridButton.setImage(listStyle.icon, for: .normal)
        }
    }

    var sortType = FileListOptions.instance.currentSortType {
        didSet {
            headerView?.sortButton.setTitle(sortType.value.translation, for: .normal)
        }
    }

    var currentDirectoryCount: FileCount?
    var selectAllMode = false
    var sortedFiles: [File] = []
    #if !ISEXTENSION
        lazy var filePresenter = FilePresenter(viewController: self, floatingPanelViewController: floatingPanelViewController)
    #endif

    private var uploadsObserver: ObservationToken?
    private var filesObserver: ObservationToken?
    private var networkObserver: ObservationToken?
    private var listStyleObserver: ObservationToken?
    private var sortTypeObserver: ObservationToken?

    private var background: EmptyTableView?
    private var lastDropPosition: DropPosition?

    var trashSort: Bool {
        #if ISEXTENSION
            return false
        #else
            return self is TrashViewController && currentDirectory.isRoot
        #endif
    }

    // MARK: - View controller lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setTitle()

        navigationItem.hideBackButtonText()

        // Set up collection view
        collectionView.register(cellView: FileCollectionViewCell.self)
        collectionView.register(cellView: FileGridCollectionViewCell.self)
        collectionView.register(UINib(nibName: headerViewIdentifier, bundle: nil), forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: headerViewIdentifier)
        if configuration.isRefreshControlEnabled {
            refreshControl.addTarget(self, action: #selector(forceRefresh), for: .valueChanged)
            collectionView.refreshControl = refreshControl
        }
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: UIConstants.listPaddingBottom, right: 0)
        (collectionView as? SwipableCollectionView)?.swipeDataSource = self
        (collectionView as? SwipableCollectionView)?.swipeDelegate = self
        collectionViewLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
        collectionViewLayout?.sectionHeadersPinToVisibleBounds = true

        // Set up current directory
        if currentDirectory == nil {
            currentDirectory = driveFileManager?.getCachedRootFile()
        }
        if configuration.showUploadingFiles {
            updateUploadCount()
        }

        // Set up multiple selection gesture
        if configuration.isMultipleSelectionEnabled {
            let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            collectionView.addGestureRecognizer(longPressGesture)
        }
        rightBarButtonItems = navigationItem.rightBarButtonItems
        leftBarButtonItems = navigationItem.leftBarButtonItems

        if configuration.supportsDrop {
            collectionView.dropDelegate = self
        }

        if configuration.supportDrag {
            collectionView.dragDelegate = self
        }

        // First load
        reloadData()

        // Set up observers
        setUpObservers()

        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func appWillEnterForeground() {
        viewWillAppear(true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setInfomaniakAppearanceNavigationBar()

        #if !ISEXTENSION
            (tabBarController as? MainTabViewController)?.tabBar.centerButton?.isEnabled = currentDirectory?.capabilities.canCreateFile ?? false
        #endif

        // Refresh data
        if isContentLoaded && !isLoadingData && currentDirectory != nil && currentDirectory.fullyDownloaded {
            getNewChanges()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MatomoUtils.track(view: ["FileList"])
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if sortedFiles.isEmpty {
            updateEmptyView()
        }
        coordinator.animate { _ in
            self.collectionView?.reloadItems(at: self.collectionView.indexPathsForVisibleItems)
            self.setSelectedCells()
        }
    }

    @IBAction func searchButtonPressed(_ sender: Any) {
        present(SearchViewController.instantiateInNavigationController(driveFileManager: driveFileManager), animated: true)
    }

    // MARK: - Overridable methods

    func getFiles(page: Int, sortType: SortType, forceRefresh: Bool, completion: @escaping (Result<[File], Error>, Bool, Bool) -> Void) {
        guard driveFileManager != nil && currentDirectory != nil else {
            DispatchQueue.main.async {
                completion(.success([]), false, true)
            }
            return
        }

        Task {
            do {
                let (children, moreComing) = try await driveFileManager.files(in: currentDirectory, page: page, sortType: sortType, forceRefresh: forceRefresh)
                completion(.success(children), moreComing, true)
            } catch {
                debugPrint(error)
                completion(.failure(error), false, true)
            }
        }
    }

    override func getNewChanges() {
        guard driveFileManager != nil && currentDirectory != nil else { return }
        isLoadingData = true
        Task {
            do {
                _ = try await driveFileManager.fileActivities(file: currentDirectory)
                self.isLoadingData = false
                self.reloadData(showRefreshControl: false, withActivities: false)
            } catch {
                self.isLoadingData = false
                if let error = error as? DriveError, error == .objectNotFound {
                    // Pop view controller
                    self.navigationController?.popViewController(animated: true)
                }
            }
        }
    }

    func setUpHeaderView(_ headerView: FilesHeaderView, isListEmpty: Bool) {
        headerView.delegate = self

        headerView.sortView.isHidden = isListEmpty

        headerView.sortButton.setTitle(sortType.value.translation, for: .normal)
        headerView.listOrGridButton.setImage(listStyle.icon, for: .normal)

        if configuration.showUploadingFiles {
            headerView.uploadCardView.isHidden = uploadingFilesCount == 0
            headerView.uploadCardView.titleLabel.text = KDriveResourcesStrings.Localizable.uploadInThisFolderTitle
            headerView.uploadCardView.setUploadCount(uploadingFilesCount)
            headerView.uploadCardView.progressView.enableIndeterminate()
        }
    }

    func updateChild(_ file: File, at index: Int) {
        let oldFile = sortedFiles[index]
        sortedFiles[index] = file

        // We don't need to call reload data if only the children were updated
        if oldFile.isContentEqual(to: file) {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.collectionView.reloadItems(at: [IndexPath(row: index, section: 0)])
        }
    }

    // MARK: - Public methods

    final func reloadData(page: Int = 1, forceRefresh: Bool = false, showRefreshControl: Bool = true, withActivities: Bool = true) {
        guard !isLoadingData || page > 1 else { return }
        isLoadingData = true
        if page == 1 && configuration.isRefreshControlEnabled && showRefreshControl {
            // Show refresh control if loading is slow
            isReloading = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.isReloading && !self.refreshControl.isRefreshing {
                    self.refreshControl.beginRefreshing()
                    let offsetPoint = CGPoint(x: 0, y: self.collectionView.contentOffset.y - self.refreshControl.frame.size.height)
                    self.collectionView.setContentOffset(offsetPoint, animated: true)
                }
            }
        }

        getFiles(page: page, sortType: sortType, forceRefresh: forceRefresh) { [weak self] result, moreComing, replaceFiles in
            guard let self = self else { return }
            self.isReloading = false
            if self.configuration.isRefreshControlEnabled {
                self.refreshControl.endRefreshing()
            }
            switch result {
            case .success(let newFiles):
                let files: [File]
                if replaceFiles || page == 1 {
                    files = newFiles
                } else {
                    files = self.sortedFiles + newFiles
                }

                self.showEmptyViewIfNeeded(files: files)
                self.reloadCollectionView(with: files)

                if moreComing {
                    self.reloadData(page: page + 1, forceRefresh: forceRefresh, showRefreshControl: showRefreshControl, withActivities: withActivities)
                } else {
                    self.isContentLoaded = true
                    self.isLoadingData = false
                    if withActivities {
                        self.getNewChanges()
                    }
                }
            case .failure(let error):
                if let error = error as? DriveError, error == .objectNotFound {
                    // Pop view controller
                    self.navigationController?.popViewController(animated: true)
                }
                if error as? DriveError != .searchCancelled {
                    UIConstants.showSnackBar(message: error.localizedDescription)
                }
                self.isLoadingData = false
            }
        }
    }

    @objc func forceRefresh() {
        reloadData(forceRefresh: true, withActivities: false)
    }

    final func setUpObservers() {
        // Upload files observer
        observeUploads()
        // File observer
        observeFiles()
        // Network observer
        observeNetwork()
        // Options observer
        observeListOptions()
    }

    final func observeUploads() {
        guard configuration.showUploadingFiles && currentDirectory != nil && uploadsObserver == nil else { return }

        uploadCountThrottler.handler = { [weak self] uploadCount in
            guard let self = self, self.isViewLoaded else { return }
            self.uploadingFilesCount = uploadCount
            let shouldHideUploadCard: Bool
            if uploadCount > 0 {
                self.headerView?.uploadCardView.setUploadCount(uploadCount)
                shouldHideUploadCard = false
            } else {
                shouldHideUploadCard = true
            }
            // Only perform reload if needed
            if shouldHideUploadCard != self.headerView?.uploadCardView.isHidden {
                self.headerView?.uploadCardView.isHidden = shouldHideUploadCard
                self.collectionView.performBatchUpdates(nil)
            }
        }
        uploadsObserver = UploadQueue.instance.observeUploadCount(self, parentId: currentDirectory.id) { [unowned self] _, uploadCount in
            self.uploadCountThrottler.call(uploadCount)
        }
    }

    final func observeFiles() {
        guard filesObserver == nil else { return }
        fileObserverThrottler.handler = { [weak self] _ in
            self?.reloadData(showRefreshControl: false)
        }
        filesObserver = driveFileManager?.observeFileUpdated(self, fileId: nil) { [unowned self] file in
            if file.id == currentDirectory?.id {
                fileObserverThrottler.call(file)
            } else if let index = sortedFiles.firstIndex(where: { $0.id == file.id }) {
                updateChild(file, at: index)
            }
        }
    }

    final func observeNetwork() {
        guard networkObserver == nil else { return }
        networkObserver = ReachabilityListener.instance.observeNetworkChange(self) { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.headerView?.offlineView.isHidden = status != .offline
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.collectionView.reloadItems(at: self.collectionView.indexPathsForVisibleItems)
            }
        }
    }

    final func observeListOptions() {
        guard listStyleObserver == nil && sortTypeObserver == nil else { return }
        // List style observer
        listStyleObserver = FileListOptions.instance.observeListStyleChange(self) { [weak self] newStyle in
            self?.listStyle = newStyle
            DispatchQueue.main.async {
                guard let self = self else { return }
                UIView.transition(with: self.collectionView, duration: 0.25, options: .transitionCrossDissolve) {
                    self.collectionViewLayout.invalidateLayout()
                    self.collectionView.reloadData()
                    self.setSelectedCells()
                }
            }
        }
        // Sort type observer
        sortTypeObserver = FileListOptions.instance.observeSortTypeChange(self) { [unowned self] newSortType in
            sortType = newSortType
            reloadData(showRefreshControl: false)
        }
    }

    final func updateUploadCount() {
        guard driveFileManager != nil && currentDirectory != nil else { return }
        uploadingFilesCount = UploadQueue.instance.getUploadingFiles(withParent: currentDirectory.id, driveId: driveFileManager.drive.id).count
    }

    final func showEmptyViewIfNeeded(type: EmptyTableView.EmptyTableViewType? = nil, files: [File]) {
        let type = type ?? configuration.emptyViewType
        if files.isEmpty {
            background = EmptyTableView.instantiate(type: type, button: false)
            updateEmptyView()
            background?.actionHandler = { [weak self] _ in
                self?.forceRefresh()
            }
            collectionView.backgroundView = background
        } else {
            collectionView.backgroundView = nil
        }
        if let headerView = headerView {
            setUpHeaderView(headerView, isListEmpty: files.isEmpty)
        }
    }

    final func removeFileFromList(id: Int) {
        let newSortedFiles = sortedFiles.filter { $0.id != id }
        reloadCollectionView(with: newSortedFiles)
        showEmptyViewIfNeeded(files: newSortedFiles)
    }

    static func instantiate(driveFileManager: DriveFileManager) -> Self {
        let viewController = storyboard.instantiateViewController(withIdentifier: storyboardIdentifier) as! Self
        viewController.driveFileManager = driveFileManager
        return viewController
    }

    // MARK: - Private methods

    private func setTitle() {
        if currentDirectory?.isRoot ?? false {
            if let rootTitle = configuration.rootTitle {
                navigationItem.title = rootTitle
            } else {
                navigationItem.title = driveFileManager?.drive.name ?? ""
            }
        } else {
            navigationItem.title = currentDirectory?.name ?? ""
        }
    }

    private func updateEmptyView() {
        if let emptyBackground = background {
            if UIDevice.current.orientation.isPortrait {
                emptyBackground.emptyImageFrameViewHeightConstant.constant = 200
            }
            if UIDevice.current.orientation.isLandscape {
                emptyBackground.emptyImageFrameViewHeightConstant.constant = 120
            }
            emptyBackground.emptyImageFrameView.cornerRadius = emptyBackground.emptyImageFrameViewHeightConstant.constant / 2
        }
    }

    private func reloadCollectionView(with files: [File]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let firstFileId = self.sortedFiles.first?.id
            let lastFileId = self.sortedFiles.last?.id
            // Reload file list with DifferenceKit
            let changeSet = StagedChangeset(source: self.sortedFiles, target: files)
            DispatchQueue.main.async {
                if changeSet.isEmpty {
                    // Invalidate layout to update header properly
                    self.collectionView.collectionViewLayout.invalidateLayout()
                }
                self.collectionView.reload(using: changeSet) { $0.changeCount > self.maxDiffChanges } setData: { files in
                    self.sortedFiles = files
                    self.updateSelectedItems(newChildren: files)
                }
                // Reload corners
                if self.listStyle == .list,
                   let oldFirstFileId = firstFileId,
                   let oldLastFileId = lastFileId,
                   let newFirstFileId = self.sortedFiles.first?.id,
                   let newLastFileId = self.sortedFiles.last?.id {
                    var indexPaths = [IndexPath]()
                    if oldFirstFileId != newFirstFileId {
                        indexPaths.append(IndexPath(item: 0, section: 0))
                        if let index = self.sortedFiles.firstIndex(where: { $0.id == oldFirstFileId }) {
                            indexPaths.append(IndexPath(item: index, section: 0))
                        }
                    }
                    if oldLastFileId != newLastFileId {
                        indexPaths.append(IndexPath(item: self.sortedFiles.count - 1, section: 0))
                        if let index = self.sortedFiles.firstIndex(where: { $0.id == oldLastFileId }) {
                            indexPaths.append(IndexPath(item: index, section: 0))
                        }
                    }
                    if !indexPaths.isEmpty {
                        self.collectionView.reloadItems(at: indexPaths)
                    }
                }
                self.setSelectedCells()
            }
        }
    }

    #if !ISEXTENSION
        private func showQuickActionsPanel(file: File) {
            if fileInformationsViewController == nil {
                fileInformationsViewController = FileActionsFloatingPanelViewController()
                fileInformationsViewController.presentingParent = self
                fileInformationsViewController.normalFolderHierarchy = configuration.normalFolderHierarchy
                floatingPanelViewController = DriveFloatingPanelController()
                floatingPanelViewController.isRemovalInteractionEnabled = true
                floatingPanelViewController.layout = FileFloatingPanelLayout(initialState: .half, hideTip: true, backdropAlpha: 0.2)
                floatingPanelViewController.set(contentViewController: fileInformationsViewController)
                floatingPanelViewController.track(scrollView: fileInformationsViewController.collectionView)
            }
            fileInformationsViewController.setFile(file, driveFileManager: driveFileManager)
            present(floatingPanelViewController, animated: true)
        }
    #endif

    // MARK: - Multiple selection

    override final func toggleMultipleSelection() {
        if selectionMode {
            navigationItem.title = nil
            headerView?.selectView.isHidden = false
            collectionView.allowsMultipleSelection = true
            navigationController?.navigationBar.prefersLargeTitles = false
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .stop, target: self, action: #selector(cancelMultipleSelection))
            navigationItem.leftBarButtonItem?.accessibilityLabel = KDriveResourcesStrings.Localizable.buttonClose
            updateSelectAllButton()
            let generator = UIImpactFeedbackGenerator()
            generator.prepare()
            generator.impactOccurred()
        } else {
            deselectAllChildren()
            headerView?.selectView.isHidden = true
            collectionView.allowsMultipleSelection = false
            navigationController?.navigationBar.prefersLargeTitles = true
            setTitle()
            navigationItem.rightBarButtonItems = rightBarButtonItems
            navigationItem.leftBarButtonItems = leftBarButtonItems
        }
        collectionView.reloadItems(at: collectionView.indexPathsForVisibleItems)
    }

    override func getItem(at indexPath: IndexPath) -> File? {
        return sortedFiles[indexPath.row]
    }

    override func getAllItems() -> [File] {
        return sortedFiles
    }

    override final func setSelectedCells() {
        if selectAllMode {
            selectedItems = Set(sortedFiles)
            for i in 0 ..< sortedFiles.count {
                collectionView.selectItem(at: IndexPath(row: i, section: 0), animated: false, scrollPosition: [])
            }
        } else {
            if selectionMode && !selectedItems.isEmpty {
                for i in 0 ..< sortedFiles.count where selectedItems.contains(sortedFiles[i]) {
                    collectionView.selectItem(at: IndexPath(row: i, section: 0), animated: false, scrollPosition: .centeredVertically)
                }
            }
        }
    }

    override final func setSelectionButtonsEnabled(moveEnabled: Bool, deleteEnabled: Bool, moreEnabled: Bool) {
        headerView?.selectView.moveButton.isEnabled = moveEnabled
        headerView?.selectView.deleteButton.isEnabled = deleteEnabled
        headerView?.selectView.moreButton.isEnabled = moreEnabled
    }

    override final func updateSelectedCount() {
        if let count = currentDirectoryCount?.count,
           selectAllMode {
            headerView?.selectView.updateTitle(count)
        } else {
            headerView?.selectView.updateTitle(selectedItems.count)
        }
        updateSelectAllButton()
    }

    // MARK: - Collection view data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sortedFiles.count
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: headerViewIdentifier, for: indexPath) as! FilesHeaderView
        setUpHeaderView(headerView, isListEmpty: sortedFiles.isEmpty)
        self.headerView = headerView
        return headerView
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cellType: UICollectionViewCell.Type
        switch listStyle {
        case .list:
            cellType = FileCollectionViewCell.self
        case .grid:
            cellType = FileGridCollectionViewCell.self
        }
        let cell = collectionView.dequeueReusableCell(type: cellType, for: indexPath) as! FileCollectionViewCell

        let file = sortedFiles[indexPath.row]
        cell.initStyle(isFirst: indexPath.row == 0, isLast: indexPath.row == sortedFiles.count - 1)
        cell.configureWith(driveFileManager: driveFileManager, file: file, selectionMode: selectionMode)
        cell.delegate = self
        if ReachabilityListener.instance.currentStatus == .offline && !file.isDirectory && !file.isAvailableOffline {
            cell.setEnabled(false)
        } else {
            cell.setEnabled(true)
        }
        if configuration.fromActivities {
            cell.moreButton.isHidden = true
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if selectAllMode {
            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
        }
    }

    // MARK: - Collection view delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if selectionMode {
            selectChild(at: indexPath)
            return
        }
        let file = sortedFiles[indexPath.row]
        if ReachabilityListener.instance.currentStatus == .offline && !file.isDirectory && !file.isAvailableOffline {
            return
        }
        #if !ISEXTENSION
            filePresenter.present(driveFileManager: driveFileManager, file: file, files: sortedFiles, normalFolderHierarchy: configuration.normalFolderHierarchy, fromActivities: configuration.fromActivities)
        #endif
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard selectionMode else {
            return
        }
        if selectAllMode {
            deselectAllChildren()
            selectChild(at: indexPath)
            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: .init(rawValue: 0))
        } else {
            deselectChild(at: indexPath)
        }
    }

    // MARK: - Swipe action collection view delegate

    func collectionView(_ collectionView: SwipableCollectionView, didSelect action: SwipeCellAction, at indexPath: IndexPath) {
        #if !ISEXTENSION
            let file = sortedFiles[indexPath.row]
            switch action {
            case .share:
                let shareVC = ShareAndRightsViewController.instantiate(driveFileManager: driveFileManager, file: file)
                navigationController?.pushViewController(shareVC, animated: true)
            case .delete:
                delete(file: file)
            default:
                break
            }
        #endif
    }

    // MARK: - Swipe action collection view data source

    func collectionView(_ collectionView: SwipableCollectionView, actionsFor cell: SwipableCell, at indexPath: IndexPath) -> [SwipeCellAction]? {
        if configuration.fromActivities || listStyle == .grid {
            return nil
        }
        var actions = [SwipeCellAction]()
        let rights = sortedFiles[indexPath.row].capabilities
        if rights.canShare {
            actions.append(.share)
        }
        if rights.canDelete {
            actions.append(.delete)
        }
        return actions
    }

    // MARK: - State restoration

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)

        coder.encode(driveFileManager.drive.id, forKey: "DriveID")
        if let currentDirectory = currentDirectory {
            coder.encode(currentDirectory.id, forKey: "DirectoryID")
        }
    }

    override func decodeRestorableState(with coder: NSCoder) {
        super.decodeRestorableState(with: coder)

        let driveId = coder.decodeInteger(forKey: "DriveID")
        let directoryId = coder.decodeInteger(forKey: "DirectoryID")

        // Drive File Manager should be consistent
        let maybeDriveFileManager: DriveFileManager?
        #if ISEXTENSION
            maybeDriveFileManager = AccountManager.instance.getDriveFileManager(for: driveId, userId: AccountManager.instance.currentUserId)
        #else
            if !(self is SharedWithMeViewController) {
                maybeDriveFileManager = (tabBarController as? MainTabViewController)?.driveFileManager
            } else {
                maybeDriveFileManager = AccountManager.instance.getDriveFileManager(for: driveId, userId: AccountManager.instance.currentUserId)
            }
        #endif
        guard let driveFileManager = maybeDriveFileManager else {
            // Handle error?
            return
        }
        self.driveFileManager = driveFileManager
        let maybeCurrentDirectory = driveFileManager.getCachedFile(id: directoryId)
        if let currentDirectory = maybeCurrentDirectory {
            self.currentDirectory = currentDirectory
        }
        if currentDirectory == nil && directoryId > DriveFileManager.constants.rootID {
            navigationController?.popViewController(animated: true)
        }
        setTitle()
        if configuration.showUploadingFiles {
            updateUploadCount()
        }
        observeUploads()
        observeFiles()
        reloadData()
    }

    // MARK: - Bulk actions

    @objc override func selectAllChildren() {
        updateSelectionButtons(selectAll: true)
        selectAllMode = true
        navigationItem.rightBarButtonItem = loadingBarButtonItem
        Task {
            do {
                let fileCount = try await driveFileManager.apiFetcher.count(of: currentDirectory)
                currentDirectoryCount = fileCount
                setSelectedCells()
                updateSelectedCount()
            } catch {
                updateSelectionButtons()
                selectAllMode = false
                updateSelectAllButton()
            }
        }
    }

    @objc override func deselectAllChildren() {
        selectAllMode = false
        if let indexPaths = collectionView.indexPathsForSelectedItems {
            for indexPath in indexPaths {
                collectionView.deselectItem(at: indexPath, animated: true)
            }
        }
        selectedItems.removeAll()
        updateSelectionButtons()
        updateSelectedCount()
    }

    private func updateSelectAllButton() {
        if !configuration.selectAllSupported {
            // Select all not supported, don't show button
            navigationItem.rightBarButtonItem = nil
        } else if selectedItems.count == sortedFiles.count || selectAllMode {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: KDriveResourcesStrings.Localizable.buttonDeselectAll, style: .plain, target: self, action: #selector(deselectAllChildren))
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: KDriveResourcesStrings.Localizable.buttonSelectAll, style: .plain, target: self, action: #selector(selectAllChildren))
        }
    }

    private func bulkMoveFiles(_ files: [File], destinationId: Int) {
        let action = BulkAction(action: .move, fileIds: files.map(\.id), destinationDirectoryId: destinationId)
        Task {
            do {
                let response = try await driveFileManager.apiFetcher.bulkAction(drive: driveFileManager.drive, action: action)
                bulkObservation(action: .move, response: response)
            } catch {
                DDLogError("Error while moving files: \(error)")
            }
        }
    }

    private func bulkMoveAll(destinationId: Int) {
        let action = BulkAction(action: .move, parentId: currentDirectory.id, destinationDirectoryId: destinationId)
        Task {
            do {
                let response = try await driveFileManager.apiFetcher.bulkAction(drive: driveFileManager.drive, action: action)
                bulkObservation(action: .move, response: response)
            } catch {
                DDLogError("Error while moving files: \(error)")
            }
        }
    }

    private func bulkDeleteFiles(_ files: [File]) {
        let action = BulkAction(action: .trash, fileIds: files.map(\.id))
        Task {
            do {
                let response = try await driveFileManager.apiFetcher.bulkAction(drive: driveFileManager.drive, action: action)
                bulkObservation(action: .trash, response: response)
            } catch {
                DDLogError("Error while deleting files: \(error)")
            }
        }
    }

    private func bulkDeleteAll() {
        let action = BulkAction(action: .trash, parentId: currentDirectory.id)
        Task {
            do {
                let response = try await driveFileManager.apiFetcher.bulkAction(drive: driveFileManager.drive, action: action)
                bulkObservation(action: .trash, response: response)
            } catch {
                DDLogError("Error while deleting files: \(error)")
            }
        }
    }

    public func bulkObservation(action: BulkActionType, response: CancelableResponse) {
        selectionMode = false
        let message: String
        switch action {
        case .trash:
            message = KDriveResourcesStrings.Localizable.fileListDeletionStartedSnackbar
        case .move:
            message = KDriveResourcesStrings.Localizable.fileListMoveStartedSnackbar
        case .copy:
            message = KDriveResourcesStrings.Localizable.fileListCopyStartedSnackbar
        }
        let progressSnack = UIConstants.showSnackBar(message: message, duration: .infinite, action: IKSnackBar.Action(title: KDriveResourcesStrings.Localizable.buttonCancel) {
            Task {
                try await self.driveFileManager.undoAction(cancelId: response.id)
            }
        })
        AccountManager.instance.mqService.observeActionProgress(self, actionId: response.id) { [weak self] actionProgress in
            DispatchQueue.main.async {
                switch actionProgress.progress.message {
                case .starting:
                    break
                case .processing:
                    switch action {
                    case .trash:
                        progressSnack?.message = KDriveResourcesStrings.Localizable.fileListDeletionInProgressSnackbar(actionProgress.progress.total - actionProgress.progress.todo, actionProgress.progress.total)
                    case .move:
                        progressSnack?.message = KDriveResourcesStrings.Localizable.fileListMoveInProgressSnackbar(actionProgress.progress.total - actionProgress.progress.todo, actionProgress.progress.total)
                    case .copy:
                        progressSnack?.message = KDriveResourcesStrings.Localizable.fileListCopyInProgressSnackbar(actionProgress.progress.total - actionProgress.progress.todo, actionProgress.progress.total)
                    }
                    self?.notifyObserversForCurrentDirectory()
                case .done:
                    switch action {
                    case .trash:
                        progressSnack?.message = KDriveResourcesStrings.Localizable.fileListDeletionDoneSnackbar
                    case .move:
                        progressSnack?.message = KDriveResourcesStrings.Localizable.fileListMoveDoneSnackbar
                    case .copy:
                        progressSnack?.message = KDriveResourcesStrings.Localizable.fileListCopyDoneSnackbar
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        progressSnack?.dismiss()
                    }
                    self?.notifyObserversForCurrentDirectory()
                case .canceled:
                    let message: String
                    switch action {
                    case .trash:
                        message = KDriveResourcesStrings.Localizable.allTrashActionCancelled
                    case .move:
                        message = KDriveResourcesStrings.Localizable.allFileMoveCancelled
                    case .copy:
                        message = KDriveResourcesStrings.Localizable.allFileDuplicateCancelled
                    }
                    UIConstants.showSnackBar(message: message)
                    self?.notifyObserversForCurrentDirectory()
                }
            }
        }
    }

    private func notifyObserversForCurrentDirectory() {
        driveFileManager.notifyObserversWith(file: currentDirectory)
    }

    // MARK: - Files header view delegate

    func sortButtonPressed() {
        let floatingPanelViewController = FloatingPanelSelectOptionViewController<SortType>.instantiatePanel(options: trashSort ? [.nameAZ, .nameZA, .newerDelete, .olderDelete, .biggest, .smallest] : [.nameAZ, .nameZA, .newer, .older, .biggest, .smallest], selectedOption: sortType, headerTitle: KDriveResourcesStrings.Localizable.sortTitle, delegate: self)
        present(floatingPanelViewController, animated: true)
    }

    func gridButtonPressed() {
        MatomoUtils.track(eventWithCategory: .displayList, name: listStyle == .grid ? "viewGrid" : "viewList")
        // Toggle grid/list
        if listStyle == .grid {
            listStyle = .list
        } else {
            listStyle = .grid
        }
        FileListOptions.instance.currentStyle = listStyle
        // Collection view will be reloaded via the observer
    }

    #if !ISEXTENSION
        func uploadCardSelected() {
            let uploadViewController = UploadQueueViewController.instantiate()
            uploadViewController.currentDirectory = currentDirectory
            navigationController?.pushViewController(uploadViewController, animated: true)
        }

        func moveButtonPressed() {
            if selectedItems.count > Constants.bulkActionThreshold {
                let selectFolderNavigationController = SelectFolderViewController.instantiateInNavigationController(driveFileManager: driveFileManager, startDirectory: currentDirectory, disabledDirectoriesSelection: [selectedItems.first?.parent ?? driveFileManager.getCachedRootFile()]) { [weak self] selectedFolder in
                    guard let self = self else { return }
                    if self.currentDirectoryCount?.count != nil && self.selectAllMode {
                        self.bulkMoveAll(destinationId: selectedFolder.id)
                    } else {
                        self.bulkMoveFiles(Array(self.selectedItems), destinationId: selectedFolder.id)
                    }
                }
                present(selectFolderNavigationController, animated: true)
            } else {
                moveSelectedItems()
            }
        }

        func deleteButtonPressed() {
            if selectedItems.count > Constants.bulkActionThreshold {
                let message: NSMutableAttributedString
                let alert: AlertTextViewController
                if let count = currentDirectoryCount?.count,
                   selectAllMode {
                    message = NSMutableAttributedString(string: KDriveResourcesStrings.Localizable.modalMoveTrashDescriptionPlural(count))
                    alert = AlertTextViewController(title: KDriveResourcesStrings.Localizable.modalMoveTrashTitle, message: message, action: KDriveResourcesStrings.Localizable.buttonMove, destructive: true) {
                        self.bulkDeleteAll()
                    }
                } else {
                    message = NSMutableAttributedString(string: KDriveResourcesStrings.Localizable.modalMoveTrashDescriptionPlural(selectedItems.count))
                    alert = AlertTextViewController(title: KDriveResourcesStrings.Localizable.modalMoveTrashTitle, message: message, action: KDriveResourcesStrings.Localizable.buttonMove, destructive: true) {
                        self.bulkDeleteFiles(Array(self.selectedItems))
                    }
                }
                present(alert, animated: true)
            } else {
                deleteSelectedItems()
            }
        }

        func menuButtonPressed() {
            showMenuForSelection()
        }
    #endif

    func removeFilterButtonPressed(_ filter: Filterable) {}
}

// MARK: - Collection view delegate flow layout

extension FileListViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        switch listStyle {
        case .list:
            // Important: subtract safe area insets
            let cellWidth = collectionView.bounds.width - collectionView.safeAreaInsets.left - collectionView.safeAreaInsets.right - leftRightInset * 2
            return CGSize(width: cellWidth, height: UIConstants.fileListCellHeight)
        case .grid:
            // Adjust cell size based on screen size
            let totalWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            let cellWidth = floor((totalWidth - gridInnerSpacing) / 2 - leftRightInset)
            return CGSize(width: min(cellWidth, 174), height: min(floor(cellWidth * 130 / 174), 130))
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        switch listStyle {
        case .list:
            return 0
        case .grid:
            return gridInnerSpacing
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat {
        switch listStyle {
        case .list:
            return 0
        case .grid:
            return gridInnerSpacing
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        return UIEdgeInsets(top: 0, left: leftRightInset, bottom: 0, right: leftRightInset)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if headerView == nil {
            headerView = self.collectionView(collectionView, viewForSupplementaryElementOfKind: UICollectionView.elementKindSectionHeader, at: IndexPath(row: 0, section: section)) as? FilesHeaderView
        }
        return headerView!.systemLayoutSizeFitting(CGSize(width: collectionView.frame.width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }

    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath, atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        return originalIndexPath
    }
}

// MARK: - File cell delegate

extension FileListViewController: FileCellDelegate {
    @objc func didTapMoreButton(_ cell: FileCollectionViewCell) {
        #if !ISEXTENSION
            guard let indexPath = collectionView.indexPath(for: cell) else {
                return
            }
            showQuickActionsPanel(file: sortedFiles[indexPath.row])
        #endif
    }
}

// MARK: - Sort options delegate

extension FileListViewController: SelectDelegate {
    func didSelect(option: Selectable) {
        guard let type = option as? SortType else { return }
        MatomoUtils.track(eventWithCategory: .fileList, name: "sort-\(type.rawValue)")
        sortType = type
        if !trashSort {
            FileListOptions.instance.currentSortType = sortType
            // Collection view will be reloaded via the observer
        } else {
            reloadData(showRefreshControl: false)
        }
    }
}

// MARK: - Switch drive delegate

#if !ISEXTENSION
    extension FileListViewController: SwitchDriveDelegate {
        func didSwitchDriveFileManager(newDriveFileManager: DriveFileManager) {
            let isDifferentDrive = newDriveFileManager.drive.objectId != driveFileManager.drive.objectId
            driveFileManager = newDriveFileManager
            filesObserver?.cancel()
            filesObserver = nil
            observeFiles()
            currentDirectory = driveFileManager.getCachedRootFile()
            if configuration.showUploadingFiles {
                updateUploadCount()
                // We stop observing the old directory and observe the new one instead
                uploadsObserver?.cancel()
                uploadsObserver = nil
                observeUploads()
            }
            if isDifferentDrive {
                sortedFiles = []
                collectionView.reloadData()
                reloadData()
                navigationController?.popToRootViewController(animated: false)
            }
        }
    }
#endif

// MARK: - Top scrollable

extension FileListViewController: TopScrollable {
    func scrollToTop() {
        if isViewLoaded {
            collectionView.scrollToTop(animated: true, navigationController: navigationController)
        }
    }
}

// MARK: - UICollectionViewDragDelegate

extension FileListViewController: UICollectionViewDragDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard indexPath.item < sortedFiles.count else { return [] }

        let draggedFile = sortedFiles[indexPath.item]
        guard draggedFile.capabilities.canMove && !driveFileManager.drive.sharedWithMe && !draggedFile.isTrashed else {
            return []
        }

        let dragAndDropFile = DragAndDropFile(file: draggedFile, userId: driveFileManager.drive.userId)
        let itemProvider = NSItemProvider(object: dragAndDropFile)
        itemProvider.suggestedName = draggedFile.name
        let draggedItem = UIDragItem(itemProvider: itemProvider)
        if let previewImageView = (collectionView.cellForItem(at: indexPath) as? FileCollectionViewCell)?.logoImage {
            draggedItem.previewProvider = {
                UIDragPreview(view: previewImageView)
            }
        }
        session.localContext = draggedFile

        return [draggedItem]
    }
}

// MARK: - UICollectionViewDropDelegate

extension FileListViewController: UICollectionViewDropDelegate {
    private func handleDropOverDirectory(_ directory: File, at indexPath: IndexPath) -> UICollectionViewDropProposal {
        guard directory.capabilities.canUpload && directory.capabilities.canMoveInto else {
            return UICollectionViewDropProposal(operation: .forbidden, intent: .insertIntoDestinationIndexPath)
        }

        if let lastDropPosition = lastDropPosition {
            if lastDropPosition.indexPath == indexPath {
                collectionView.cellForItem(at: indexPath)?.isHighlighted = true
                if UIConstants.dropDelay > lastDropPosition.time.timeIntervalSinceNow {
                    self.lastDropPosition = nil
                    collectionView.cellForItem(at: indexPath)?.isHighlighted = false
                    #if !ISEXTENSION
                        filePresenter.present(driveFileManager: driveFileManager, file: directory, files: sortedFiles, normalFolderHierarchy: configuration.normalFolderHierarchy, fromActivities: configuration.fromActivities)
                    #endif
                }
            } else {
                collectionView.cellForItem(at: lastDropPosition.indexPath)?.isHighlighted = false
                self.lastDropPosition = DropPosition(indexPath: indexPath)
            }
        } else {
            lastDropPosition = DropPosition(indexPath: indexPath)
        }
        return UICollectionViewDropProposal(operation: .copy, intent: .insertIntoDestinationIndexPath)
    }

    func handleLocalDrop(localItemProviders: [NSItemProvider], destinationDirectory: File) {
        for localFile in localItemProviders {
            localFile.loadObject(ofClass: DragAndDropFile.self) { [weak self] itemProvider, _ in
                guard let self = self else { return }
                if let itemProvider = itemProvider as? DragAndDropFile,
                   let file = itemProvider.file {
                    let destinationDriveFileManager = self.driveFileManager!
                    if itemProvider.driveId == destinationDriveFileManager.drive.id && itemProvider.userId == destinationDriveFileManager.drive.userId {
                        if destinationDirectory.id == file.parentId { return }
                        Task {
                            do {
                                let (response, _) = try await destinationDriveFileManager.move(file: file, to: destinationDirectory)
                                UIConstants.showCancelableSnackBar(message: KDriveResourcesStrings.Localizable.fileListMoveFileConfirmationSnackbar(1, destinationDirectory.name), cancelSuccessMessage: KDriveResourcesStrings.Localizable.allFileMoveCancelled, cancelableResponse: response, driveFileManager: destinationDriveFileManager)
                            } catch {
                                UIConstants.showSnackBar(message: error.localizedDescription)
                            }
                        }
                    } else {
                        // TODO: enable copy from different driveFileManager
                        DispatchQueue.main.async {
                            UIConstants.showSnackBar(message: KDriveResourcesStrings.Localizable.errorMove)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        UIConstants.showSnackBar(message: DriveError.unknownError.localizedDescription)
                    }
                }
            }
        }
    }

    func handleExternalDrop(externalFiles: [NSItemProvider], destinationDirectory: File) {
        if !externalFiles.isEmpty {
            UIConstants.showSnackBar(message: KDriveResourcesStrings.Localizable.snackbarProcessingUploads)
            _ = FileImportHelper.instance.importItems(externalFiles) { [weak self] importedFiles, errorCount in
                guard let self = self else { return }
                if errorCount > 0 {
                    DispatchQueue.main.async {
                        UIConstants.showSnackBar(message: KDriveResourcesStrings.Localizable.snackBarUploadError(errorCount))
                    }
                }
                guard !importedFiles.isEmpty else {
                    return
                }
                do {
                    try FileImportHelper.instance.upload(files: importedFiles, in: destinationDirectory, drive: self.driveFileManager.drive)
                } catch {
                    DispatchQueue.main.async {
                        UIConstants.showSnackBar(message: error.localizedDescription)
                    }
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        if let indexPath = destinationIndexPath,
           indexPath.row < sortedFiles.count && sortedFiles[indexPath.item].isDirectory {
            if let draggedFile = session.localDragSession?.localContext as? File,
               draggedFile.id == sortedFiles[indexPath.item].id {
                if let indexPath = lastDropPosition?.indexPath {
                    collectionView.cellForItem(at: indexPath)?.isHighlighted = false
                }
                return UICollectionViewDropProposal(operation: .forbidden, intent: .insertIntoDestinationIndexPath)
            } else {
                return handleDropOverDirectory(sortedFiles[indexPath.item], at: indexPath)
            }
        } else {
            if let indexPath = lastDropPosition?.indexPath {
                collectionView.cellForItem(at: indexPath)?.isHighlighted = false
            }
            return UICollectionViewDropProposal(operation: .copy, intent: .insertAtDestinationIndexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        let itemProviders = coordinator.items.map(\.dragItem.itemProvider)
        // We don't display iOS's progress indicator because we use our own snackbar
        coordinator.session.progressIndicatorStyle = .none

        let destinationDirectory: File
        if let indexPath = coordinator.destinationIndexPath,
           indexPath.row < sortedFiles.count && sortedFiles[indexPath.item].isDirectory &&
           sortedFiles[indexPath.item].capabilities.canUpload {
            destinationDirectory = sortedFiles[indexPath.item]
        } else {
            destinationDirectory = currentDirectory
        }

        if let lastHighlightedPath = lastDropPosition?.indexPath {
            collectionView.cellForItem(at: lastHighlightedPath)?.isHighlighted = false
        }

        let localFiles = itemProviders.filter { $0.canLoadObject(ofClass: DragAndDropFile.self) }
        handleLocalDrop(localItemProviders: localFiles, destinationDirectory: destinationDirectory)

        let externalFiles = itemProviders.filter { !$0.canLoadObject(ofClass: DragAndDropFile.self) }
        handleExternalDrop(externalFiles: externalFiles, destinationDirectory: destinationDirectory)
    }
}
