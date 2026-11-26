import AppKit
import Observation

@MainActor @Observable
final class BrowserSession {
    struct PasteRequest: Sendable {
        let urls: [URL]
        let version: Int
        let movesFiles: Bool
    }

    private(set) var pins: [QuickAccessPin]
    var favorites: [URL] { pins.filter(\.isFolder).map(\.url) }
    private var folderViews: [String: FolderViewPreference]
    @ObservationIgnored var searchRoots: ((UUID) -> [URL])?
    var showHidden = UserDefaults.standard.bool(forKey: "showHidden")
    var showPreview = true
    var isTransferring = false
    var localMutationCount = 0
    let history: FileHistory
    let frequentFiles: FrequentFiles
    @ObservationIgnored var enqueuePaste: ((PasteRequest, URL) -> Bool)?
    @ObservationIgnored var mutationFinished: (() -> Void)?
    let viewSettings: FileViewSettings
    private let clipboard: NSPasteboard
    private var hasFileURLs = false
    private var isPasting = false
    @ObservationIgnored private var clipboardVersion: Int?
    @ObservationIgnored private var cutVersion: Int?
    private let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    private let storage: WorkspaceStorage
    private(set) var stash: [URL]

    init(clipboard: NSPasteboard? = nil, defaults: UserDefaults = .standard) {
        self.clipboard = clipboard ?? .general
        storage = WorkspaceStorage(defaults: defaults)
        history = FileHistory(defaults: defaults)
        frequentFiles = FrequentFiles(defaults: defaults)
        stash = storage.stash
        pins = storage.pins
        folderViews = storage.folderViews
        viewSettings = FileViewSettings.restore(defaults: defaults)
    }

    func togglePin(_ url: URL, isFolder: Bool) {
        if let index = pins.firstIndex(where: { $0.id == url.path }) { pins.remove(at: index) }
        else { pins.append(QuickAccessPin(url: url.standardizedFileURL, isFolder: isFolder)) }
        storage.savePins(pins)
    }

    func movePin(_ source: String, to target: String) {
        guard source != target, let from = pins.firstIndex(where: { $0.id == source }),
              let to = pins.firstIndex(where: { $0.id == target }) else { return }
        let item = pins.remove(at: from)
        pins.insert(item, at: to)
        storage.savePins(pins)
    }

    func folderView(at url: URL) -> FolderViewPreference? { folderViews[url.standardizedFileURL.path] }

    func storeFolderView(_ preference: FolderViewPreference, at url: URL) {
        let key = url.standardizedFileURL.path
        guard folderViews[key] != preference else { return }
        folderViews[key] = preference
        storage.saveFolderViews(folderViews)
    }

    func updateStash(adding urls: [URL] = [], removing removed: [URL] = []) {
        let paths = Set(removed.map(FileSystem.locationKey))
        var next = stash.filter { !paths.contains(FileSystem.locationKey($0)) }
        var known = Set(next.map(FileSystem.locationKey))
        next += urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { known.insert(FileSystem.locationKey($0)).inserted }
        guard next != stash else { return }
        stash = next
        storage.saveStash(next)
    }

    func finishMutation() {
        localMutationCount -= 1
        mutationFinished?()
    }

    func updateStash(for changes: [FileRelocation], keepingReferences: Bool) -> [FileRelocation] {
        guard !changes.isEmpty, !stash.isEmpty else { return changes }
        let paths = Set(stash.map(FileSystem.locationKey))
        let recorded = changes.map { change -> FileRelocation in
            var change = change
            change.wasInStash = paths.contains(FileSystem.locationKey(change.original))
            return change
        }
        let stashed = recorded.filter(\.wasInStash)
        if !stashed.isEmpty {
            updateStash(adding: keepingReferences ? stashed.map(\.current) : [], removing: stashed.map(\.original))
        }
        return recorded
    }

    var canPaste: Bool { hasFileURLs && !isPasting }

    func refreshClipboard() {
        let version = clipboard.changeCount
        guard clipboardVersion != version else { return }
        clipboardVersion = version
        hasFileURLs = clipboard.availableType(from: [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]) != nil
        if cutVersion != version { cutVersion = nil }
    }

    @discardableResult
    func writeFiles(_ urls: [URL], cut: Bool) -> Bool {
        guard !urls.isEmpty else { return false }
        clipboard.clearContents()
        let written = clipboard.writeObjects(urls.map { $0 as NSURL })
        cutVersion = written && cut ? clipboard.changeCount : nil
        refreshClipboard()
        return written
    }

    func writePath(_ path: String) {
        clipboard.clearContents()
        clipboard.setString(path, forType: .string)
        refreshClipboard()
    }

    func beginPaste() -> PasteRequest? {
        refreshClipboard()
        guard !isPasting,
              let urls = clipboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [URL],
              !urls.isEmpty, let version = clipboardVersion, version == clipboard.changeCount else { return nil }
        var paths = Set<String>()
        let uniqueURLs = urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
        isPasting = true
        return PasteRequest(urls: uniqueURLs, version: version, movesFiles: cutVersion == version)
    }

    func finishPaste(_ request: PasteRequest, retrying failed: [URL]) {
        defer {
            isPasting = false
            refreshClipboard()
        }
        guard request.movesFiles, cutVersion == request.version, clipboard.changeCount == request.version else { return }
        if failed.isEmpty {
            clipboard.clearContents()
        } else if failed.count < request.urls.count {
            // Keep only items that still need to be moved; the rest are already at the destination.
            writeFiles(failed, cut: true)
        }
    }
}

@MainActor @Observable
final class BrowserWorkspace {
    @MainActor struct Tab: Identifiable {
        let id = UUID()
        var layout: PaneLayout
        var focusedPaneID: UUID
        var title: String?
        var comparisonPair: DirectoryPair?
        var linkedPaneIDs: [UUID] = []
        var proportions: [UUID: CGFloat] = [:]
        var showsQuickAccess = false

        init(snapshot: TabSnapshot, session: BrowserSession) {
            var proportions: [UUID: CGFloat] = [:]
            let tree = PaneLayout.restore(snapshot.layout, session: session, proportions: &proportions)
            let panes = tree.browsers
            self.layout = tree
            self.proportions = proportions
            title = snapshot.title
            comparisonPair = snapshot.comparisonPair
            showsQuickAccess = snapshot.showsQuickAccess == true
            if let pair = comparisonPair, pair.linked,
               let first = panes.first(where: { pair.target(for: $0.directory, from: pair.left, to: pair.right) != nil }),
               let second = panes.first(where: { $0 !== first && pair.target(for: $0.directory, from: pair.right, to: pair.left) != nil }) {
                linkedPaneIDs = [first.id, second.id]
            }
            focusedPaneID = panes[panes.indices.contains(snapshot.activePane) ? snapshot.activePane : 0].id
        }

        var snapshot: TabSnapshot {
            TabSnapshot(layout: layout.snapshot(proportions: proportions),
                        activePane: browsers.firstIndex { $0.id == focusedPaneID } ?? 0,
                        title: title, comparisonPair: comparisonPair, showsQuickAccess: showsQuickAccess ? true : nil)
        }

        init(browser: BrowserModel) {
            layout = .pane(browser)
            focusedPaneID = browser.id
        }

        var browsers: [BrowserModel] { layout.browsers }
        var focusedBrowser: BrowserModel {
            let panes = browsers
            return panes.first { $0.id == focusedPaneID } ?? panes[0]
        }
    }

    @MainActor struct TransferTarget: Identifiable {
        let number: Int
        let browser: BrowserModel
        nonisolated var id: UUID { browser.id }
        var title: String { "面板 \(number) · \(browser.directoryName)" }

        func accepts(_ urls: [URL], operation: PaneTransferOperation) -> Bool {
            guard browser.canQueueTransfer, !urls.isEmpty else { return false }
            return operation == .copy || urls.contains { $0.deletingLastPathComponent().path != browser.directory.path }
        }
    }

    struct TransferChoice: Identifiable {
        let id = UUID()
        let urls: [URL]
        let operation: PaneTransferOperation
        let targets: [TransferTarget]
        let fromStash: Bool
    }

    private let session: BrowserSession
    private let storage: WorkspaceStorage
    private(set) var namedWorkspaces: [NamedWorkspace]
    private(set) var smartFolders: [SmartFolder]
    private(set) var remoteLocations: [RemoteLocation]
    private(set) var organizationRules: [OrganizationRule]
    private(set) var connectingRemote: UUID?
    private(set) var unmountingVolumes: Set<URL> = []
    var windowsKeyBindings: Bool {
        didSet { storage.defaults.set(windowsKeyBindings, forKey: "wfolder.windowsKeys") }
    }
    var stash: [URL] { session.stash }
    var presentedTool: WorkspaceTool?
    private enum AssistantPlacement: String { case sheet, sidebar, hiddenSidebar }
    private static let assistantPlacementKey = "wfolder.ai.assistantPlacement"
    private var assistantPlacement: AssistantPlacement {
        didSet { storage.defaults.set(assistantPlacement.rawValue, forKey: Self.assistantPlacementKey) }
    }
    var showsAIAssistantSidebar: Bool { assistantPlacement == .sidebar }
    private(set) var assistantFocusRequest = 0
    private(set) var tabs: [Tab]
    private(set) var activeIndex = 0
    private(set) var addressFocusRequest = 0
    private(set) var paneFocusRequest = 0
    let transfers = TransferQueue()
    var transferChoice: TransferChoice?
    var destinationRequest: TransferDestinationRequest?
    private(set) var recentDestinations: [URL]
    var showsOperations = false
    var operationsTab: FileOperationsTab = .transfers
    var history: FileHistory { session.history }
    var frequentFiles: FrequentFiles { session.frequentFiles }
    var quickAccessPins: [QuickAccessPin] { session.pins }

    init(directory: URL, clipboard: NSPasteboard? = nil, restoreSession: Bool = false,
         defaults: UserDefaults = .standard) {
        let session = BrowserSession(clipboard: clipboard, defaults: defaults)
        let storage = WorkspaceStorage(defaults: defaults)
        self.session = session
        self.storage = storage
        namedWorkspaces = storage.named
        smartFolders = storage.smartFolders
        remoteLocations = storage.remoteLocations
        organizationRules = storage.organizationRules
        recentDestinations = storage.recentDestinations
        windowsKeyBindings = defaults.bool(forKey: "wfolder.windowsKeys")
        assistantPlacement = defaults.string(forKey: Self.assistantPlacementKey)
            .flatMap(AssistantPlacement.init(rawValue:)) ?? .sheet
        let restores = defaults.object(forKey: "wfolder.restoreLastSession") as? Bool ?? true
        if restoreSession, restores, let last = storage.lastSession, !last.tabs.isEmpty {
            tabs = last.tabs.map { Tab(snapshot: $0, session: session) }
            activeIndex = tabs.indices.contains(last.activeTab) ? last.activeTab : 0
            session.showPreview = last.showsPreview
        } else {
            tabs = [Tab(browser: BrowserModel(directory: directory, session: session))]
            tabs[0].showsQuickAccess = restoreSession
        }
        session.enqueuePaste = { [weak self] request, directory in
            guard let self else { return false }
            return self.transfer(request.urls, into: directory, operation: request.movesFiles ? .move : .copy) { [weak self] job in
                let completed = Set(job.completed.map(FileSystem.locationKey))
                let failed = FileSystem.selectedRoots(request.urls).filter { !completed.contains(FileSystem.locationKey($0)) }
                self?.session.finishPaste(request, retrying: failed)
            }
        }
        session.mutationFinished = { [weak self] in self?.advanceTransfers() }
        session.searchRoots = { [weak self] id in self?.searchDirectories(for: id) ?? [] }
    }

    var snapshot: SessionSnapshot {
        SessionSnapshot(tabs: tabs.map(\.snapshot), activeTab: activeIndex, showsPreview: session.showPreview)
    }

    func saveSession(_ snapshot: SessionSnapshot) { storage.saveSession(snapshot) }

    func openAIAssistant() {
        if assistantPlacement == .sheet {
            presentedTool = .aiAssistant
        } else {
            pinAIAssistant()
        }
    }

    func pinAIAssistant() {
        assistantPlacement = .sidebar
        assistantFocusRequest += 1
    }

    func hideAIAssistantSidebar() {
        if showsAIAssistantSidebar { assistantPlacement = .hiddenSidebar }
    }

    func openAIAssistantAsSheet() {
        assistantPlacement = .sheet
        presentedTool = .aiAssistant
    }

    func saveWorkspace(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !namedWorkspaces.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        namedWorkspaces.append(NamedWorkspace(id: UUID(), name: name, tab: activeTab.snapshot))
        storage.saveNamed(namedWorkspaces)
        return true
    }

    func openWorkspace(_ saved: NamedWorkspace) {
        var tab = Tab(snapshot: saved.tab, session: session)
        tab.title = saved.name
        tabs.insert(tab, at: activeIndex + 1)
        activeIndex += 1
    }

    func resizeSplit(_ id: UUID, ratio: CGFloat) {
        guard activeTab.proportions[id] != ratio else { return }
        tabs[activeIndex].proportions[id] = ratio
    }

    func storeInStash(_ urls: [URL]) {
        session.updateStash(adding: urls)
    }

    func removeFromStash(_ urls: [URL]) {
        session.updateStash(removing: urls)
    }

    var activeTab: Tab { tabs[activeIndex] }
    var activeBrowser: BrowserModel { activeTab.focusedBrowser }
    var folderBrowsers: [BrowserModel] { activeTab.browsers.filter { !$0.isVirtual } }
    var directoryBrowser: BrowserModel? { activeBrowser.isVirtual ? folderBrowsers.first : activeBrowser }
    var showHidden: Bool { session.showHidden }
    var isTransferring: Bool { session.isTransferring }
    var canClosePane: Bool { activeTab.browsers.count > 1 && !activeBrowser.busy }

    func searchDirectories(for pane: UUID) -> [URL] {
        tabs.first(where: { $0.browsers.contains { $0.id == pane } })?.browsers
            .filter { !$0.isVirtual }.map(\.directory) ?? []
    }

    func showFolderBrowser() { tabs[activeIndex].showsQuickAccess = false }

    func moveQuickAccessPin(_ source: String, to target: String) {
        session.movePin(source, to: target)
    }

    func openQuickAccessItem(_ url: URL) {
        let tab = activeTab.id
        Task {
            let address = await Task.detached { BrowserAddress.resolve(fileURL: url, packagesAsFiles: true) }.value
            guard activeTab.id == tab else { return }
            guard let address else {
                activeBrowser.issue = BrowserIssue(title: "找不到项目", message: url.path)
                return
            }
            switch address {
            case .folder(let folder): navigateToFolder(folder)
            case .file(let file):
                let entry = await Task.detached { FileEntry.read(file) }.value
                guard activeTab.id == tab else { return }
                BrowserFileActions(model: activeBrowser, workspace: self).open(entry)
            }
        }
    }

    func openQuickAccess() {
        if let tab = tabs.first(where: \.showsQuickAccess) { selectTab(tab.id) }
        else {
            openTab()
            tabs[activeIndex].showsQuickAccess = true
        }
    }

    func closeFocusedItem() {
        guard !activeBrowser.busy else { return }
        if activeTab.browsers.count > 1 { closePane() }
        else { closeTab(activeTab.id) }
    }

    func activatePane(_ browser: BrowserModel) {
        guard activeTab.focusedPaneID != browser.id, activeTab.browsers.contains(where: { $0 === browser }) else { return }
        tabs[activeIndex].focusedPaneID = browser.id
    }

    func switchPane() {
        let panes = activeTab.browsers
        guard panes.count > 1, let current = panes.firstIndex(where: { $0 === activeBrowser }) else { return }
        activatePane(panes[(current + 1) % panes.count])
        paneFocusRequest += 1
    }

    func switchPane(toward direction: PaneDirection) {
        guard let next = activeTab.layout.neighbor(of: activeBrowser.id, direction: direction,
                                                   proportions: activeTab.proportions),
              let pane = activeTab.browsers.first(where: { $0.id == next }) else { return }
        activatePane(pane)
        paneFocusRequest += 1
    }

    func splitPane(_ direction: PaneSplitDirection) {
        showFolderBrowser()
        let current = activeBrowser
        let source = directoryBrowser ?? current
        let newPane = BrowserModel(directory: source.directory, session: session, mountedRoot: source.mountedRoot)
        newPane.viewMode = source.viewMode
        newPane.grouping = source.grouping
        insertPane(newPane, beside: current, direction: direction)
    }

    func openStashPane() {
        if let existing = activeTab.browsers.first(where: \.isStash) {
            activatePane(existing)
            paneFocusRequest += 1
            return
        }
        let pane = BrowserModel(directory: activeBrowser.directory, session: session, isStash: true)
        insertPane(pane, beside: activeBrowser, direction: .sideBySide)
    }

    @discardableResult func openSmartFolder(_ folder: SmartFolder) -> BrowserModel {
        if let existing = activeTab.browsers.first(where: { $0.smartFolder?.id == folder.id }) {
            activatePane(existing)
            if existing.smartFolder == folder { existing.refresh() }
            else { existing.updateSmartFolder(folder) }
            paneFocusRequest += 1
            return existing
        }
        let pane = BrowserModel(directory: folder.root, session: session, smartFolder: folder)
        insertPane(pane, beside: activeBrowser, direction: .sideBySide)
        return pane
    }

    func showSmartFolderResults(_ folder: SmartFolder) {
        for tab in tabs {
            if let pane = tab.browsers.first(where: { $0.smartFolder?.id == folder.id }) {
                selectTab(tab.id)
                activatePane(pane)
                paneFocusRequest += 1
                return
            }
        }
        openSmartFolder(folder)
    }

    func saveSmartFolder(_ folder: SmartFolder) {
        smartFolders.removeAll { $0.id == folder.id }
        smartFolders.append(folder)
        storage.saveSmartFolders(smartFolders)
        for browser in tabs.flatMap(\.browsers) where browser.smartFolder?.id == folder.id {
            browser.updateSmartFolder(folder)
        }
    }

    func removeSmartFolder(_ folder: SmartFolder) {
        smartFolders.removeAll { $0.id == folder.id }
        storage.saveSmartFolders(smartFolders)
    }

    func openArchivePane(_ archive: FileEntry) {
        if let existing = activeTab.browsers.first(where: { $0.isArchivePane && $0.zipArchive?.id == archive.id }) {
            activatePane(existing)
            return
        }
        insertPane(BrowserModel(directory: archive.url.deletingLastPathComponent(), session: session, archive: archive),
                   beside: activeBrowser, direction: .sideBySide)
    }

    func saveRemote(_ location: RemoteLocation) {
        guard !remoteLocations.contains(where: { $0.address == location.address }) else { return }
        remoteLocations.append(location)
        storage.saveRemoteLocations(remoteLocations)
    }

    func removeRemote(_ location: RemoteLocation) {
        remoteLocations.removeAll { $0.id == location.id }
        storage.saveRemoteLocations(remoteLocations)
    }

    func connectRemote(_ location: RemoteLocation) async throws {
        guard connectingRemote == nil else { return }
        connectingRemote = location.id
        defer { connectingRemote = nil }
        let url = try await Task.detached(priority: .userInitiated) { try location.connect() }.value
        openLocationPane(url, mounted: true)
    }

    func openLocationPane(_ url: URL, mounted: Bool = false) {
        showFolderBrowser()
        if let pane = folderBrowsers.first(where: { $0.directory.path == url.path }) {
            activatePane(pane)
            pane.refreshIfStarted()
        } else {
            let pane = BrowserModel(directory: url, session: session, mountedRoot: mounted ? url : nil)
            insertPane(pane, beside: activeBrowser, direction: .sideBySide)
        }
    }

    func refreshMountedPanes() {
        for browser in tabs.flatMap(\.browsers) where browser.mountedRoot != nil {
            browser.refreshIfStarted()
        }
    }

    func unmountLocation(_ volume: MountedLocation) async {
        let title = "无法\(volume.unmountTitle)「\(volume.name)」"
        if let request = transfers.active?.request,
           ([request.directory] + request.sources).contains(where: { MountedLocation.contains(volume.url, directory: $0) }) {
            activeBrowser.issue = BrowserIssue(title: title, message: "这个位置正在传输文件，请等待传输完成后重试。")
            return
        }
        guard unmountingVolumes.insert(volume.id).inserted else { return }
        defer { unmountingVolumes.remove(volume.id) }
        do {
            try await Task.detached(priority: .userInitiated) { try volume.unmount() }.value
            refreshMountedPanes()
        } catch {
            activeBrowser.issue = BrowserIssue(title: title, message: error.localizedDescription)
        }
    }

    func closeArchivePane(_ pane: BrowserModel) {
        guard activeTab.browsers.contains(where: { $0 === pane }) else { return }
        activatePane(pane)
        if activeTab.browsers.count > 1 {
            closePane()
        } else {
            tabs[activeIndex] = Tab(browser: BrowserModel(directory: pane.directory, session: session))
        }
    }

    func navigateToFolder(_ url: URL) {
        showFolderBrowser()
        if let browser = directoryBrowser {
            activatePane(browser)
            browser.navigate(to: url)
        } else {
            insertPane(BrowserModel(directory: url, session: session), beside: activeBrowser, direction: .sideBySide)
        }
    }

    func revealInFolder(_ url: URL) {
        navigateToFolder(url.deletingLastPathComponent())
        activeBrowser.revealItem(at: url)
    }

    func openFinderItems(_ items: [BrowserAddress]) {
        var directories: [URL] = []
        var selections: [URL: [URL]] = [:]
        for item in items {
            let directory: URL
            let file: URL?
            switch item {
            case .folder(let url): (directory, file) = (url, nil)
            case .file(let url): (directory, file) = (url.deletingLastPathComponent(), url)
            }
            if selections[directory] == nil {
                directories.append(directory)
                selections[directory] = []
            }
            if let file { selections[directory, default: []].append(file) }
        }

        for directory in directories {
            openTab(at: directory)
            if let files = selections[directory], !files.isEmpty {
                activeBrowser.revealItems(inCurrentFolder: files)
                activeBrowser.showPreview = true
            }
        }
        paneFocusRequest += 1
    }

    func followAddress(_ address: BrowserAddress) {
        if let browser = directoryBrowser {
            activatePane(browser)
            browser.followAddress(address)
        } else {
            switch address {
            case .folder(let url): navigateToFolder(url)
            case .file(let url):
                revealInFolder(url)
                activeBrowser.showPreview = true
            }
        }
        paneFocusRequest += 1
    }

    private func insertPane(_ pane: BrowserModel, beside current: BrowserModel, direction: PaneSplitDirection) {
        showFolderBrowser()
        tabs[activeIndex].layout = activeTab.layout.inserting(pane, beside: current.id, direction: direction)
        tabs[activeIndex].focusedPaneID = pane.id
        paneFocusRequest += 1
    }

    func closePane() {
        let panes = activeTab.browsers
        let closing = activeBrowser
        guard !closing.busy, panes.count > 1, let index = panes.firstIndex(where: { $0 === closing }),
              let layout = activeTab.layout.removing(closing.id) else { return }
        closing.stopSmartSearch()
        tabs[activeIndex].layout = layout
        let branchIDs = layout.splitIDs
        tabs[activeIndex].proportions = activeTab.proportions.filter { branchIDs.contains($0.key) }
        tabs[activeIndex].focusedPaneID = panes[(index + 1) % panes.count].id
        paneFocusRequest += 1
    }

    func transferTargets(from browser: BrowserModel) -> [TransferTarget] {
        activeTab.browsers.enumerated().compactMap { index, pane in
            pane === browser || pane.isVirtual ? nil : TransferTarget(number: index + 1, browser: pane)
        }
    }

    func requestTransfer(_ operation: PaneTransferOperation) {
        let browser = activeBrowser
        let urls = browser.selectedEntries.map(\.url)
        let targets = transferTargets(from: browser).filter { $0.accepts(urls, operation: operation) }
        guard !browser.busy, !targets.isEmpty else { return }
        if targets.count == 1, let target = targets.first {
            transfer(urls, into: target.browser.directory, operation: operation, fromStash: browser.isStash)
        } else {
            transferChoice = TransferChoice(urls: urls, operation: operation, targets: targets, fromStash: browser.isStash)
        }
    }

    func chooseTransferDestination(_ operation: PaneTransferOperation, items: [FileEntry], from browser: BrowserModel) {
        guard !items.isEmpty, !browser.busy else { return }
        destinationRequest = TransferDestinationRequest(urls: items.map(\.url), operation: operation,
                                                        base: browser.directory, fromStash: browser.isStash)
    }

    @discardableResult
    func transfer(_ urls: [URL], into directory: URL, operation: PaneTransferOperation, fromStash: Bool = false,
                  onFinish: ((TransferJob) -> Void)? = nil) -> Bool {
        let sources = FileSystem.selectedRoots(urls.filter(\.isFileURL).map(\.standardizedFileURL))
        guard !sources.isEmpty, directory.isFileURL else { return false }
        let target = directory.standardizedFileURL
        recentDestinations.removeAll { $0.path == target.path }
        recentDestinations.insert(target, at: 0)
        recentDestinations = Array(recentDestinations.prefix(12))
        storage.saveRecentDestinations(recentDestinations)
        transfers.append(PaneTransfer(sources: sources, directory: directory.standardizedFileURL,
                                      operation: operation, fromStash: fromStash), onFinish: onFinish)
        advanceTransfers()
        return true
    }

    func retryTransfer(_ job: TransferJob) {
        transfer(job.failures.map(\.source), into: job.request.directory,
                 operation: job.request.operation, fromStash: job.request.fromStash)
    }

    private func advanceTransfers() {
        guard transfers.hasWaiting, !session.isTransferring, session.localMutationCount == 0 else { return }
        session.isTransferring = true
        transfers.startNext { [weak self] job in
            guard let self else { return }
            let relocations = self.session.updateStash(for: job.moved, keepingReferences: false)
            self.frequentFiles.relocate(job.backups, trashing: true)
            self.frequentFiles.relocate(relocations)
            let moving = job.request.operation == .move
            self.history.record(moving ? .move : .copy, count: moving ? relocations.count : job.completed.count,
                                detail: job.request.directory.path, relocations: relocations + job.backups)
            self.refreshLocations(job.request.sources, directories: [job.request.directory])
            self.session.isTransferring = false
            self.advanceTransfers()
        }
    }

    var hasFileMutations: Bool { session.isTransferring || session.localMutationCount > 0 }

    func cancelTransfersForQuit() {
        for job in transfers.jobs.reversed() { transfers.cancel(job) }
    }

    var canUndoFileOperation: Bool {
        !session.isTransferring && session.localMutationCount == 0 && history.latestUndo != nil
    }

    func revealOperations(_ tab: FileOperationsTab) {
        operationsTab = tab
        showsOperations = true
    }

    func undoFileOperation() {
        guard canUndoFileOperation, let entry = history.latestUndo else { return }
        session.isTransferring = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { entry.undo() }.value
            history.didUndo(entry, result: result)
            frequentFiles.relocate(result.restored, restoring: true)
            let stashed = result.restored.filter(\.wasInStash)
            session.updateStash(adding: stashed.map(\.original), removing: stashed.map(\.current))
            refreshLocations(result.restored.flatMap { [$0.original, $0.current] })
            session.isTransferring = false
            advanceTransfers()
        }
    }

    func saveComparisonPair(left: BrowserModel, right: BrowserModel, linked: Bool) {
        tabs[activeIndex].comparisonPair = DirectoryPair(left: left.directory, right: right.directory, linked: linked)
        tabs[activeIndex].linkedPaneIDs = linked ? [left.id, right.id] : []
    }

    func followLinkedNavigation(from browser: BrowserModel) {
        let tab = activeTab
        guard let pair = tab.comparisonPair, pair.linked, tab.linkedPaneIDs.count == 2,
              let side = tab.linkedPaneIDs.firstIndex(of: browser.id),
              let other = tab.browsers.first(where: { $0.id == tab.linkedPaneIDs[1 - side] }) else { return }
        let origin = browser.directory
        let previous = other.directory
        guard let target = pair.target(for: origin, from: side == 0 ? pair.left : pair.right,
                                       to: side == 0 ? pair.right : pair.left), target.path != previous.path else { return }
        Task {
            let exists = await Task.detached {
                if case .folder = BrowserAddress.resolve(fileURL: target) { return true }
                return false
            }.value
            guard exists, activeTab.id == tab.id, activeTab.comparisonPair == pair, browser.directory == origin,
                  other.directory == previous, activeTab.browsers.contains(where: { $0 === other }) else { return }
            other.navigate(to: target)
        }
    }

    func saveOrganizationRule(_ rule: OrganizationRule) {
        if let index = organizationRules.firstIndex(where: { $0.id == rule.id }) {
            organizationRules[index] = rule
        } else {
            organizationRules.append(rule)
        }
        storage.saveOrganizationRules(organizationRules)
    }

    func removeOrganizationRule(_ rule: OrganizationRule) {
        organizationRules.removeAll { $0.id == rule.id }
        storage.saveOrganizationRules(organizationRules)
    }

    func applyOrganization(_ plan: OrganizationPlan, scope: AIAutomationScope? = nil) async -> FileOperationResult? {
        guard !session.isTransferring, session.localMutationCount == 0 else { return nil }
        session.isTransferring = true
        defer { session.isTransferring = false; advanceTransfers() }
        let worker = Task.detached(priority: .userInitiated) { plan.run(scope: scope) }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        let changes = session.updateStash(for: result.relocations, keepingReferences: true)
        session.history.record(.move, count: changes.count, detail: plan.rule.destination.path, relocations: changes)
        session.frequentFiles.relocate(changes, trashing: false)
        refreshLocations(changes.flatMap { [$0.original, $0.current] } + result.revealed,
                         directories: [plan.rule.source, plan.rule.destination])
        return result
    }

    func applyComparison(_ comparison: FolderComparison, selected: Set<String>, direction: FolderCopyDirection,
                         sync: Bool) async -> FileOperationResult? {
        guard !session.isTransferring, session.localMutationCount == 0 else { return nil }
        session.isTransferring = true
        let result = await Task.detached(priority: .userInitiated) {
            comparison.copy(selected, direction: direction, updating: sync)
        }.value
        session.isTransferring = false
        for browser in activeTab.browsers { browser.refreshIfStarted() }
        advanceTransfers()
        return result
    }

    private func refreshLocations(_ items: [URL], directories: [URL] = []) {
        let changed = Set((items.map { $0.deletingLastPathComponent() } + directories).map { FileSystem.physicalDirectory($0).path })
        for browser in tabs.flatMap(\.browsers) {
            if browser.smartFolder != nil || browser.isStash || changed.contains(FileSystem.physicalDirectory(browser.directory).path)
                || (browser.hasSearch && browser.searchScope != .current) {
                browser.refreshIfStarted()
            }
        }
    }

    func openTab(at directory: URL? = nil) {
        let browser = BrowserModel(directory: directory ?? directoryBrowser?.directory ?? activeBrowser.directory, session: session)
        tabs.insert(Tab(browser: browser), at: activeIndex + 1)
        activeIndex += 1
        tabs[activeIndex].showsQuickAccess = directory == nil &&
            (storage.defaults.object(forKey: "wfolder.newTabsShowQuickAccess") as? Bool ?? true)
    }

    func selectTab(_ id: Tab.ID) {
        if let index = tabs.firstIndex(where: { $0.id == id }) { activeIndex = index }
    }

    func selectAdjacentTab(forward: Bool) {
        let offset = forward ? 1 : tabs.count - 1
        activeIndex = (activeIndex + offset) % tabs.count
    }

    @discardableResult
    func closeTab(_ id: Tab.ID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let nextIndex = min(activeIndex - (index < activeIndex ? 1 : 0), tabs.count - 2)
        activeIndex = nextIndex
        tabs.remove(at: index)
        return true
    }

    func focusAddress() {
        showFolderBrowser()
        addressFocusRequest += 1
    }

    func refreshClipboard() { session.refreshClipboard() }

    func setShowHidden(_ visible: Bool) {
        guard visible != session.showHidden else { return }
        session.showHidden = visible
        UserDefaults.standard.set(visible, forKey: "showHidden")
        for browser in tabs.flatMap(\.browsers) { browser.refreshIfStarted() }
    }
}
