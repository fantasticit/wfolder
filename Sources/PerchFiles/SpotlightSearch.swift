import AppKit
import Observation
import SwiftUI

enum SpotlightField: String, CaseIterable, Identifiable {
    case contents = "内容", tags = "标签"
    var id: Self { self }

    func predicate(for query: String) -> NSPredicate {
        switch self {
        case .contents: return NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemTextContentKey, query)
        case .tags: return NSPredicate(format: "ANY %K CONTAINS[cd] %@", "kMDItemUserTags", query)
        }
    }
}

enum SpotlightScope: String, CaseIterable, Identifiable {
    case workspace = "当前工作区", all = "全局"
    var id: Self { self }
}

@MainActor @Observable
final class SpotlightSearch: NSObject {
    struct Hit: Identifiable, Sendable {
        let name: String
        let path: String
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    private(set) var hits: [Hit] = []
    private(set) var busy = false
    private(set) var completed = false
    private(set) var error: String?
    @ObservationIgnored private var query: NSMetadataQuery?

    func start(text: String, field: SpotlightField, directories: [URL]?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        start(predicate: value.isEmpty ? nil : field.predicate(for: value), directories: directories)
    }

    func start(predicate: NSPredicate?, directories: [URL]?) {
        cancel()
        hits = []
        completed = false
        error = nil
        guard let predicate else { return }
        let metadata = NSMetadataQuery()
        metadata.predicate = predicate
        if let directories {
            metadata.searchScopes = Array(Set(directories.map { $0.resolvingSymlinksInPath() }))
        } else {
            metadata.searchScopes = [NSMetadataQueryLocalComputerScope]
        }
        metadata.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        query = metadata
        busy = true
        NotificationCenter.default.addObserver(self, selector: #selector(finish),
                                               name: .NSMetadataQueryDidFinishGathering, object: metadata)
        if !metadata.start() {
            cancel()
            error = "无法启动 Spotlight 搜索。"
        }
    }

    func cancel() {
        if let query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            query.stop()
        }
        query = nil
        busy = false
    }

    @objc private func finish(_ notification: Notification) {
        guard let query, notification.object as? NSMetadataQuery === query else { return }
        query.stop()
        var seen = Set<String>()
        hits = (0..<query.resultCount).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  seen.insert(path).inserted else { return nil }
            let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent
            return Hit(name: name, path: path)
        }
        cancel()
        completed = true
    }
}

struct SpotlightSearchView: View {
    let workspace: BrowserWorkspace
    @ViewState private var search = SpotlightSearch()
    @ViewState private var text = ""
    @ViewState private var field = SpotlightField.contents
    @ViewState private var scope = SpotlightScope.workspace
    @ViewState private var selected: String?
    @ViewState private var entry: FileEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spotlight 搜索").font(.headline)
            HStack {
                TextField("搜索内容或标签", text: $text).onSubmit(start)
                Picker("匹配", selection: $field) {
                    ForEach(SpotlightField.allCases) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Picker("范围", selection: $scope) {
                    ForEach(SpotlightScope.allCases) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Button("搜索", action: start)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 0) {
                results
                Divider()
                Group {
                    if let entry, !entry.isFolder {
                        FilePreview(entry: entry)
                    } else {
                        ContentUnavailableView("选择要预览的文件", systemImage: "eye")
                    }
                }
                .frame(width: 275)
            }
            HStack {
                if search.completed { Text("\(search.hits.count) 项匹配").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if search.busy { Button("停止") { search.cancel() } }
                Button("定位到文件") { reveal() }.disabled(selected == nil)
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 800, height: 510)
        .onDisappear { search.cancel() }
        .task(id: selected) {
            entry = nil
            guard let selected else { return }
            let url = URL(fileURLWithPath: selected)
            let value = await Task.detached { FileEntry.read(url) }.value
            if !Task.isCancelled { entry = value }
        }
    }

    @ViewBuilder private var results: some View {
        if search.busy {
            ProgressView("正在查询 Spotlight 索引…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.hits.isEmpty {
            ContentUnavailableView(search.error ?? (search.completed ? "没有索引结果" : "输入关键词开始搜索"),
                                   systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(search.hits, selection: $selected) { hit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.name).lineLimit(1)
                    Text(hit.url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { reveal(hit.path) }
                .tag(hit.id)
            }
        }
    }

    private func start() {
        selected = nil
        let roots = scope == .workspace ? workspace.folderBrowsers.map(\.directory) : nil
        search.start(text: text, field: field, directories: roots)
    }

    private func reveal(_ path: String? = nil) {
        guard let path = path ?? selected else { return }
        let url = URL(fileURLWithPath: path)
        workspace.revealInFolder(url)
        workspace.activeBrowser.showPreview = true
        workspace.presentedTool = nil
    }
}
