import SwiftUI
import UniformTypeIdentifiers

enum SearchFileKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case any = "所有类型", folder = "文件夹", image = "图片", video = "视频", audio = "音频"
    case document = "文档与文本", archive = "压缩包"
    var id: Self { self }

    func matches(_ entry: FileEntry) -> Bool {
        switch self {
        case .any: return true
        case .folder: return entry.isFolder
        case .image: return entry.contentType?.conforms(to: .image) == true
        case .video: return entry.mediaKind == .video
        case .audio: return entry.mediaKind == .audio
        case .document:
            if entry.isFolder || entry.mediaKind != nil { return false }
            return entry.sourceLanguage != nil || entry.isMarkdown ||
                [.text, .pdf, .spreadsheet, .presentation].contains { entry.contentType?.conforms(to: $0) == true } ||
                ["doc", "docx", "pages", "numbers", "key", "odt"].contains(entry.url.pathExtension.lowercased())
        case .archive: return FileArchive.canExtract(entry.url) || entry.contentType?.conforms(to: .archive) == true
        }
    }
}

struct SearchConditions: Codable, Equatable, Sendable {
    var filename = ""
    var contents = ""
    var tag = ""
    var extensions = ""
    var minimumMB = ""
    var days = ""
    var recursive = true
    var kind: SearchFileKind?

    var valid: Bool {
        (minimumMB.isEmpty || Self.positiveNumber(minimumMB) != nil) &&
        (days.isEmpty || Int(days).map { (1...36_500).contains($0) } == true)
    }

    fileprivate var suffixes: Set<String> {
        Set(extensions.split(whereSeparator: { ",，;； ".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() })
    }

    fileprivate var minimumBytes: Double? { Self.positiveNumber(minimumMB).map { $0 * 1_000_000 } }

    private static func positiveNumber(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }
}

struct SmartFolder: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var root: URL
    var conditions = SearchConditions()
    var semantics: SearchSemantics?
    var feedbackContext: SearchMemoryContext? = nil
    var limitedTo: Set<String>? = nil

    @MainActor func results(showHidden: Bool,
                            reportProgress: (@Sendable (FolderSearchProgress) -> Void)? = nil) async throws -> FolderSearchResults {
        let query = SpotlightSearch()
        let text = conditions.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexedPaths: Set<String>?
        if text.isEmpty {
            indexedPaths = nil
        } else {
            query.start(text: text, field: .contents, directories: [root])
            defer { query.cancel() }
            let deadline = ContinuousClock.now + .seconds(20)
            while query.busy {
                guard ContinuousClock.now < deadline else { throw SearchFailure(message: "Spotlight 内容搜索超时，请缩小搜索范围后重试。") }
                try await Task.sleep(for: .milliseconds(50))
            }
            if let error = query.error { throw SearchFailure(message: error) }
            indexedPaths = Set(query.hits.map { $0.url.resolvingSymlinksInPath().path })
        }
        let readsContents = conditions.kind == nil || conditions.kind == .any || conditions.kind == .document
        let semanticIndex = try await (readsContents ? semantics?.indexedMatches(in: root) : nil) ?? []
        let worker = Task.detached(priority: .userInitiated) {
            let suffixes = conditions.suffixes
            let minimumBytes = conditions.minimumBytes
            let matchesConcepts = semantics?.matcher(in: root, readsContents: readsContents, indexed: semanticIndex)
            let since = Int(conditions.days).flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: .now) }
            return try FileSystem.search(root, query: conditions.filename, showHidden: showHidden,
                                         recursive: conditions.recursive, includesCandidate: { url in
                if let limitedTo, !limitedTo.contains(url.standardizedFileURL.path) { return false }
                if !suffixes.isEmpty && !suffixes.contains(url.pathExtension.lowercased()) { return false }
                if let since {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if date.map({ $0 >= since }) != true { return false }
                }
                if let indexedPaths, !indexedPaths.contains(url.path) {
                    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true &&
                        indexedPaths.contains(url.resolvingSymlinksInPath().path)
                }
                return true
            }, includesEntry: { entry in
                if !suffixes.isEmpty && entry.isFolder { return false }
                if let kind = conditions.kind, !kind.matches(entry) { return false }
                if let minimumBytes, Double(entry.size ?? 0) < minimumBytes { return false }
                if !conditions.tag.isEmpty {
                    let tags = (try? entry.url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                    if !tags.contains(where: { $0.localizedCaseInsensitiveContains(conditions.tag) }) { return false }
                }
                return matchesConcepts?(entry) ?? true
            }, reportProgress: reportProgress)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

struct SearchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SearchConditionFields: View {
    @Binding var conditions: SearchConditions

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                TextField("文件名", text: $conditions.filename)
                TextField("Spotlight 内容", text: $conditions.contents)
            }
            GridRow {
                TextField("扩展名，如 pdf, zip", text: $conditions.extensions)
                TextField("Finder 标签", text: $conditions.tag)
            }
            GridRow {
                TextField("最小大小（MB）", text: $conditions.minimumMB)
                TextField("最近修改（天）", text: $conditions.days)
            }
        }
        HStack {
            Picker("类型", selection: Binding(get: { conditions.kind ?? .any }, set: { conditions.kind = $0 })) {
                ForEach(SearchFileKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Spacer()
            Toggle("包含子目录", isOn: $conditions.recursive)
        }
    }
}

struct AdvancedSearchView: View {
    let workspace: BrowserWorkspace
    @ViewState private var folder: SmartFolder

    init(workspace: BrowserWorkspace, existing: SmartFolder? = nil) {
        self.workspace = workspace
        _folder = State(initialValue: existing ?? SmartFolder(name: "", root: workspace.activeBrowser.directory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("高级搜索").font(.headline)
            HStack {
                Text(folder.root.path).lineLimit(1).truncationMode(.middle).help(folder.root.path)
                Spacer()
                DirectoryChooser(title: "选择范围…", directory: $folder.root)
            }
            SearchConditionFields(conditions: $folder.conditions)
            Divider()
            TextField("智能文件夹名称", text: $folder.name)
            HStack {
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存到侧栏") { open(save: true) }
                    .disabled(!folder.conditions.valid || folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("在面板中搜索") { open(save: false) }
                    .disabled(!folder.conditions.valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 570)
    }

    private func open(save: Bool) {
        var search = folder
        search.name = search.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.name.isEmpty { search.name = "搜索结果" }
        if save { workspace.saveSmartFolder(search) }
        else { search.id = UUID() }
        workspace.presentedTool = nil
        workspace.openSmartFolder(search)
    }
}

struct DirectoryChooser: View {
    let title: String
    @Binding var directory: URL

    var body: some View {
        Button(title) {
            guard let window = NSApp.keyWindow else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = directory
            panel.beginSheetModal(for: window) { result in
                if result == .OK, let url = panel.url { directory = url }
            }
        }
    }
}
