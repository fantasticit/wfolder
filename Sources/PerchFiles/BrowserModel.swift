import AppKit
import Observation

struct Place: Identifiable, Sendable {
    let name: String
    let symbol: String
    let url: URL
    var id: String { url.path }
}

enum FileColumn: String, CaseIterable, Codable, Sendable {
    case name = "名称", kind = "类型", modified = "修改日期", size = "大小"
}

struct BrowserIssue: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct FilePrompt: Identifiable {
    enum Kind { case newFolder, newFile(NewFileFormat), rename(FileEntry), trash([FileEntry]) }
    let id = UUID()
    let kind: Kind
    let title: String
    let initial: String
    let directory: URL
}

struct FileOperationResult: Sendable {
    struct Failure: Sendable {
        let source: URL
        let message: String
    }

    var revealed: [URL] = []
    var failures: [Failure] = []
    var relocations: [FileRelocation] = []

    nonisolated static func apply(to sources: [URL], _ operation: (URL) throws -> URL?) -> Self {
        var result = Self()
        for source in sources {
            do {
                if let destination = try operation(source) { result.revealed.append(destination) }
            } catch {
                result.failures.append(Failure(source: source, message: error.localizedDescription))
            }
        }
        return result
    }

    var failureSummary: String {
        var lines = failures.prefix(8).map { "\($0.source.lastPathComponent) · \($0.message)" }
        if failures.count > lines.count { lines.append("另有 \(failures.count - lines.count) 项失败。") }
        return lines.joined(separator: "\n")
    }
}

@MainActor @Observable
final class BrowserModel {
    let id = UUID()
    let isStash: Bool
    private(set) var directory: URL
    private(set) var entries: [FileEntry] = []
    private(set) var contentsID = UUID()
    private(set) var listing = FileListing(entries: [])
    private(set) var loading = true
    private(set) var loadError: String?
    private(set) var busy = false
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    private(set) var sortColumn = FileColumn.name
    private(set) var ascending = true
    private(set) var selectedIDs: Set<URL> = []
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            updateSearch(reset: true, debounce: true)
        }
    }
    var searchScope: FolderSearchScope = .current {
        didSet {
            if searchScope != oldValue { updateSearch(reset: true) }
        }
    }
    private(set) var searchingDescendants = false
    private(set) var searchNotice: String?
    var presentsSearch = false
    var issue: BrowserIssue?
    var prompt: FilePrompt?
    var expandedPreview: FileEntry?
    private(set) var zipArchive: FileEntry?
    var showPreview: Bool {
        get { session.showPreview }
        set { session.showPreview = newValue }
    }
    var viewMode: FileViewMode = .details {
        didSet { if viewMode != oldValue { updateGroupedRows() } }
    }
    var grouping: FileGrouping = .none {
        didSet { if grouping != oldValue { updateGroupedRows() } }
    }
    private(set) var groupedRows: GroupedFileRows?
    var viewSettings: FileViewSettings {
        get { session.viewSettings }
        set { session.viewSettings = newValue }
    }
    var favorites: [URL] { session.favorites }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var loadTask: Task<DirectoryContents, Error>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var searchTask: Task<(FolderSearchResults, FileListing), Error>?
    @ObservationIgnored private var searchRevision = 0
    @ObservationIgnored private var completedSearch: FolderSearchResults?
    @ObservationIgnored private var groupTask: Task<GroupedFileRows, Error>?
    @ObservationIgnored private var pendingReveal: Set<String> = []
    @ObservationIgnored private var explicitlyRevealedFile: URL?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchRefresh: Task<Void, Never>?
    private let session: BrowserSession

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let defaults: [Place] = [
        Place(name: "个人目录", symbol: "house", url: home),
        Place(name: "桌面", symbol: "macwindow", url: home.appendingPathComponent("Desktop", isDirectory: true)),
        Place(name: "文稿", symbol: "doc.text", url: home.appendingPathComponent("Documents", isDirectory: true)),
        Place(name: "下载", symbol: "arrow.down.to.line", url: home.appendingPathComponent("Downloads", isDirectory: true)),
        Place(name: "图片", symbol: "photo", url: home.appendingPathComponent("Pictures", isDirectory: true)),
        Place(name: "应用程序", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications", isDirectory: true))
    ]

    init(directory: URL, session: BrowserSession, isStash: Bool = false) {
        self.session = session
        self.isStash = isStash
        self.directory = directory.standardizedFileURL
    }

    convenience init(snapshot: PaneSnapshot, session: BrowserSession) {
        let folder = snapshot.directory.isFileURL ? snapshot.directory : Self.home
        self.init(directory: folder, session: session, isStash: snapshot.isStash == true)
        viewMode = snapshot.viewMode
        grouping = snapshot.grouping
        sortColumn = snapshot.sortColumn
        ascending = snapshot.ascending
    }

    var snapshot: PaneSnapshot {
        PaneSnapshot(directory: directory, viewMode: viewMode, grouping: grouping,
                     sortColumn: sortColumn, ascending: ascending, isStash: isStash ? true : nil)
    }

    func start() {
        guard !started else { return }
        started = true
        watchLocation()
        refresh()
    }

    deinit {
        loadTask?.cancel()
        searchTask?.cancel()
        groupTask?.cancel()
        watcher?.cancel()
        watchRefresh?.cancel()
    }

    var visibleEntries: [FileEntry] { listing.entries }
    var hasSearch: Bool { !query.isEmpty }
    private var searchesDescendants: Bool { !isStash && hasSearch && searchScope == .descendants }

    var selected: FileEntry? {
        guard selectedIDs.count == 1, let id = selectedIDs.first, let row = listing.rows[id] else { return nil }
        return listing.entries[row]
    }

    var selectedEntries: [FileEntry] {
        selectedIDs.compactMap { listing.rows[$0] }.sorted().map { listing.entries[$0] }
    }

    func select(_ ids: Set<URL>) {
        let visible = ids.filter { listing.rows[$0] != nil }
        guard selectedIDs != visible else { return }
        selectedIDs = visible
        if isStash, started { watchLocation() }
    }

    private func applyListing(_ next: FileListing) {
        guard listing.entries != next.entries else { return }
        listing = next
        select(selectedIDs)
        updateGroupedRows()
    }

    private func updateGroupedRows() {
        groupTask?.cancel()
        groupedRows = nil
        guard viewMode == .details, grouping != .none, !listing.entries.isEmpty else { return }
        let listing = self.listing
        let grouping = self.grouping
        let task = Task.detached(priority: .userInitiated) {
            try GroupedFileRows(listing: listing, grouping: grouping)
        }
        groupTask = task
        Task { [weak self] in
            guard let rows = try? await task.value, !task.isCancelled else { return }
            self?.groupedRows = rows
        }
    }

    var parent: URL? {
        isStash || directory.path == "/" ? nil : directory.deletingLastPathComponent()
    }

    var directoryName: String {
        isStash ? "文件暂存架" : Self.placeName(for: directory)
    }

    var crumbs: [URL] {
        var path = directory
        var result = [path]
        while path.path != "/" {
            path.deleteLastPathComponent()
            result.append(path)
        }
        return result.reversed()
    }

    static func placeName(for url: URL) -> String {
        if url.path == "/" { return "磁盘" }
        if let place = defaults.first(where: { $0.url.path == url.path }) { return place.name }
        return FileManager.default.displayName(atPath: url.path)
    }

    func navigate(to url: URL, revealing item: URL? = nil) {
        guard !isStash else { return }
        closeZip()
        guard url.standardizedFileURL.path != directory.path else { return }
        backStack.append(directory)
        forwardStack.removeAll()
        arrive(at: url, revealing: item)
    }

    func back() {
        if zipArchive != nil { closeZip(); return }
        guard let url = backStack.popLast() else { return }
        forwardStack.append(directory)
        arrive(at: url)
    }

    func forward() {
        closeZip()
        guard let url = forwardStack.popLast() else { return }
        backStack.append(directory)
        arrive(at: url)
    }

    private func arrive(at url: URL, revealing item: URL? = nil) {
        directory = url.standardizedFileURL
        entries = []
        contentsID = UUID()
        applyListing(FileListing(entries: []))
        select([])
        pendingReveal = []
        clearSearch()
        explicitlyRevealedFile = item
        loadError = nil
        watchLocation()
        refresh(revealing: item.map { [$0] } ?? [])
    }

    func refresh(revealing urls: [URL] = []) {
        if !urls.isEmpty { pendingReveal = Set(urls.map { $0.standardizedFileURL.path }) }
        loadListing()
    }

    func showContainingFolder(of entry: FileEntry) {
        revealItem(at: entry.url)
    }

    func revealItem(at url: URL) {
        closeZip()
        let folder = url.deletingLastPathComponent()
        if folder.path != directory.path {
            navigate(to: folder, revealing: url)
            return
        }
        clearSearch()
        if let entry = entries.first(where: { $0.url.path == url.path }) {
            select([entry.id])
            return
        }
        // An explicit path can point to a hidden item while hidden items are filtered out.
        explicitlyRevealedFile = url
        refresh(revealing: [url])
    }

    private func clearSearch() {
        presentsSearch = false
        query = ""
    }

    func refreshIfStarted() {
        if started { refresh() }
    }

    private func loadListing(from cached: [FileEntry]? = nil, reuseSearch: Bool = false) {
        revision += 1
        let request = revision
        let url = directory
        let stash = isStash ? session.stash : nil
        let showHidden = session.showHidden
        let explicitlyRevealedFile = self.explicitlyRevealedFile
        let sortColumn = self.sortColumn
        let ascending = self.ascending
        let query = self.query
        loadTask?.cancel()
        if entries.isEmpty { loading = true }
        let task = Task.detached(priority: .userInitiated) {
            var files = try cached ?? stash.map { urls in
                try urls.map { url in
                    try Task.checkCancellation()
                    return FileEntry.read(URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath))
                }
            } ?? FileSystem.list(url, showHidden: showHidden)
            if let item = explicitlyRevealedFile, !files.contains(where: { $0.url.path == item.path }),
               FileManager.default.fileExists(atPath: item.path) {
                files.append(FileEntry.read(item))
            }
            try Task.checkCancellation()
            let sorted = Self.sorted(files, by: sortColumn, ascending: ascending)
            try Task.checkCancellation()
            return DirectoryContents(entries: sorted, visible: .matching(sorted, query: query))
        }
        loadTask = task
        Task { [weak self] in
            let result = await task.result
            guard let self, request == self.revision else { return }
            self.loadTask = nil
            self.loading = false
            switch result {
            case .success(let content):
                self.loadError = nil
                if self.entries != content.entries {
                    self.entries = content.entries
                    self.contentsID = UUID()
                }
                if self.searchesDescendants {
                    self.updateSearch(reuseResults: reuseSearch)
                } else {
                    self.applyListing(query == self.query ? content.visible : .matching(content.entries, query: self.query))
                    self.revealPendingItems()
                }
            case .failure(let error):
                self.cancelSearch()
                self.pendingReveal = []
                self.entries = []
                self.contentsID = UUID()
                self.applyListing(FileListing(entries: []))
                self.select([])
                self.loadError = error.localizedDescription
            }
        }
    }

    private func revealPendingItems() {
        guard !pendingReveal.isEmpty else { return }
        let targets = visibleEntries.filter { pendingReveal.contains($0.url.standardizedFileURL.path) }
        pendingReveal = []
        select(Set(targets.map(\.id)))
    }

    private func cancelSearch() {
        searchRevision += 1
        searchTask?.cancel()
        searchTask = nil
        searchingDescendants = false
        searchNotice = nil
        completedSearch = nil
    }

    private func updateSearch(reset: Bool = false, debounce: Bool = false, reuseResults: Bool = false) {
        guard searchesDescendants, loadError == nil else {
            cancelSearch()
            applyListing(.matching(entries, query: query))
            revealPendingItems()
            return
        }
        if reset {
            searchNotice = nil
            applyListing(.matching(entries, query: query))
        }
        if !reuseResults { completedSearch = nil }
        let cached = completedSearch
        let directory = self.directory
        let query = self.query
        let showHidden = session.showHidden
        let sortColumn = self.sortColumn
        let ascending = self.ascending
        searchRevision += 1
        let request = searchRevision
        searchTask?.cancel()
        searchingDescendants = true
        let task = Task.detached(priority: .userInitiated) {
            if debounce { try await Task.sleep(for: .milliseconds(180)) }
            let results = try cached ?? FileSystem.search(directory, query: query, showHidden: showHidden)
            let sorted = Self.sorted(results.entries, by: sortColumn, ascending: ascending)
            try Task.checkCancellation()
            return (results, FileListing(entries: sorted))
        }
        searchTask = task
        Task { [weak self] in
            let result = await task.result
            guard let self, self.searchRevision == request else { return }
            self.searchTask = nil
            self.searchingDescendants = false
            switch result {
            case .success(let (matches, listing)):
                self.completedSearch = matches
                self.searchNotice = matches.unreadable == 0 ? nil : "\(matches.unreadable) 个子目录无法读取"
                self.applyListing(listing)
                self.revealPendingItems()
            case .failure(let error):
                self.searchNotice = "搜索中断：\(error.localizedDescription)"
                self.revealPendingItems()
            }
        }
    }

    private var watchedLocation: URL? { isStash ? selected?.url : directory }

    private func watchLocation() {
        watcher?.cancel()
        watcher = nil
        watchRefresh?.cancel()
        guard let url = watchedLocation else { return }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 as Int32 }
            return Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, self.watchedLocation == url else { return }
            self.watchRefresh?.cancel()
            self.watchRefresh = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.watchedLocation == url, !self.busy else { return }
                if self.isStash { self.watchLocation() }
                self.refresh()
            }
        }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.resume()
    }

    func sort(by column: FileColumn, ascending direction: Bool? = nil) {
        ascending = direction ?? (sortColumn == column ? !ascending : true)
        sortColumn = column
        loadListing(from: loadTask == nil && loadError == nil ? entries : nil, reuseSearch: true)
    }

    private nonisolated static func sorted(_ entries: [FileEntry], by sortColumn: FileColumn,
                                           ascending: Bool) -> [FileEntry] {
        entries.sorted { first, second in
            if first.isFolder != second.isFolder { return first.isFolder }
            let order: ComparisonResult
            switch sortColumn {
            case .name: order = first.name.localizedStandardCompare(second.name)
            case .kind: order = first.kind.localizedStandardCompare(second.kind)
            case .modified:
                order = (first.modified ?? .distantPast).compare(second.modified ?? .distantPast)
            case .size:
                let a = first.size ?? -1, b = second.size ?? -1
                order = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            }
            if order == .orderedSame {
                let names = first.filename.localizedStandardCompare(second.filename)
                return names == .orderedSame ? first.filename < second.filename : names == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    func openEntry(_ entry: FileEntry) {
        if entry.isFolder {
            navigate(to: entry.url)
        } else if ZipContents.supports(entry.url) {
            zipArchive = entry
        } else {
            openWithDefaultApp(entry)
        }
    }

    func closeZip() { if zipArchive != nil { zipArchive = nil } }

    func openWithDefaultApp(_ entry: FileEntry) {
        if !NSWorkspace.shared.open(entry.url) {
            issue = BrowserIssue(title: "无法打开文件", message: entry.name)
        }
    }

    func extractZip(_ archive: FileEntry, paths: Set<String>, folder: String, into destination: URL,
                    onCompletion: @escaping (Int) -> Void) {
        perform("无法解压所选项目", at: directory) {
            let extracted = try ZipContents.extract(paths, in: folder, archive: archive, into: destination)
            return FileOperationResult(revealed: extracted)
        } onCompletion: { result in
            onCompletion(result.revealed.count)
        }
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.path == url.path } }

    func toggleFavorite(_ url: URL) {
        if isFavorite(url) {
            session.favorites.removeAll { $0.path == url.path }
        } else {
            session.favorites.append(url)
        }
        UserDefaults.standard.set(favorites.map(\.path), forKey: "favorites")
    }

    func copy(_ items: [FileEntry], cut: Bool = false) {
        guard !items.isEmpty else { return }
        if !session.writeFiles(items.map(\.url), cut: cut) {
            issue = BrowserIssue(title: cut ? "无法剪切" : "无法复制", message: "无法写入系统剪贴板。")
        }
    }

    func copyPath(_ entry: FileEntry) {
        session.writePath(entry.url.path)
    }

    var canRenameItems: Bool { !busy && !session.isTransferring && !loading && loadError == nil }
    var canModifyDirectory: Bool { !isStash && canRenameItems }
    var canQueueTransfer: Bool { !isStash && !loading && loadError == nil }
    var canPaste: Bool { canQueueTransfer && session.canPaste }

    func paste() {
        guard canQueueTransfer, let request = session.beginPaste() else { return }
        if session.enqueuePaste?(request, directory) != true {
            session.finishPaste(request, retrying: request.urls)
        }
    }

    func batchRename(_ entries: [FileEntry], rule: BatchRenameRule) {
        guard canModifyDirectory else { return }
        perform("无法批量重命名", at: directory, history: .batchRename) {
            try BatchRenamePlan(items: entries, rule: rule).apply()
        }
    }

    func duplicate(_ entry: FileEntry) {
        perform("无法制作副本", at: directory) { FileOperationResult(revealed: [try FileSystem.duplicate(entry)]) }
    }

    func compress(_ items: [FileEntry]) {
        guard let first = items.first else { return }
        let parent = first.url.deletingLastPathComponent()
        let archiveFolder = items.allSatisfy { $0.url.deletingLastPathComponent().path == parent.path }
            ? parent : directory
        perform("无法压缩", at: directory) {
            FileOperationResult(revealed: [try FileArchive.compress(items.map(\.url), in: archiveFolder)])
        }
    }

    func extract(_ entry: FileEntry) {
        perform("无法解压", at: directory) { FileOperationResult(revealed: [try FileArchive.extract(entry.url)]) }
    }

    func askNewFolder() { prompt = FilePrompt(kind: .newFolder, title: "新建文件夹", initial: "", directory: directory) }
    func askNewFile(format: NewFileFormat = .txt) {
        prompt = FilePrompt(kind: .newFile(format), title: "新建文件", initial: "未命名", directory: directory)
    }
    func askRename(_ entry: FileEntry) {
        guard canRenameItems else { return }
        prompt = FilePrompt(kind: .rename(entry), title: "重命名", initial: entry.filename, directory: directory)
    }
    func askTrash(_ items: [FileEntry]) {
        guard !busy, let first = items.first else { return }
        prompt = FilePrompt(kind: .trash(items), title: "移到废纸篓", initial: first.name, directory: directory)
    }

    func submit(_ prompt: FilePrompt, value: String, format: NewFileFormat? = nil) {
        switch prompt.kind {
        case .newFolder:
            perform("无法新建文件夹", at: prompt.directory) {
                FileOperationResult(revealed: [try FileSystem.makeFolder(in: prompt.directory, name: value)])
            }
        case .newFile(let initialFormat):
            let fileFormat = format ?? initialFormat
            perform("无法新建文件", at: prompt.directory) {
                FileOperationResult(revealed: [try FileSystem.makeFile(in: prompt.directory, name: value, format: fileFormat)])
            } onCompletion: { [weak self] _ in
                if self?.directory == prompt.directory { self?.query = "" }
            }
        case .rename(let entry):
            perform("无法重命名", at: prompt.directory, history: .rename) {
                let target = try FileSystem.rename(entry, name: value)
                let changes = target.path.utf8.elementsEqual(entry.url.path.utf8) ? []
                    : [FileRelocation(original: entry.url, current: target)]
                return FileOperationResult(revealed: [target], relocations: changes)
            }
        case .trash(let items):
            perform("无法移到废纸篓", at: prompt.directory, history: .trash) {
                var result = FileOperationResult()
                for url in FileSystem.selectedRoots(items.map(\.url)) {
                    do {
                        if let target = try FileSystem.trash(url) {
                            result.relocations.append(FileRelocation(original: url, current: target))
                        }
                    } catch {
                        result.failures.append(.init(source: url, message: error.localizedDescription))
                    }
                }
                return result
            }
        }
    }

    private func perform(
        _ title: String, at location: URL, history: FileHistoryEntry.Kind? = nil,
        operation: @escaping @Sendable () throws -> FileOperationResult,
        onCompletion: @escaping (FileOperationResult) -> Void = { _ in }
    ) {
        guard !busy, !session.isTransferring else { return }
        busy = true
        session.localMutationCount += 1
        watchRefresh?.cancel()
        Task {
            let result = await Task.detached(priority: .userInitiated, operation: operation).result
            busy = false
            defer { session.finishMutation() }
            switch result {
            case .success(let outcome):
                if let history {
                    let changes = session.updateStash(for: outcome.relocations, keepingReferences: history != .trash)
                    session.history.record(history, count: changes.count, detail: location.path, relocations: changes)
                }
                onCompletion(outcome)
                if !outcome.failures.isEmpty { issue = BrowserIssue(title: title, message: outcome.failureSummary) }
                if directory == location { refresh(revealing: outcome.revealed) }
            case .failure(let error):
                issue = BrowserIssue(title: title, message: error.localizedDescription)
                if directory == location { refresh() }
            }
        }
    }
}
