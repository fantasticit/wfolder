import PDFKit
import SwiftUI

struct ContentIndexView: View {
    let workspace: BrowserWorkspace
    var selectedFolder: URL? = nil
    var includesDescendants = true
    var showHidden = false
    @ViewState private var root: URL?
    @ViewState private var query = ""
    @ViewState private var coverage: ContentIndex.Coverage?
    @ViewState private var matches: [ContentIndex.Match] = []
    @ViewState private var selected: ContentIndex.Match?
    @ViewState private var issue: String?
    @ViewState private var meter = TransferMeter()
    @ViewState private var build: Task<Void, Never>?
    @ViewState private var search: Task<Void, Never>?
    @ViewState private var submitted = false
    @ViewState private var scopeReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LocalFolderField(title: "在此文件夹内搜索", url: $root).disabled(build != nil)
            HStack {
                TextField("输入文件里的文字", text: $query)
                    .accessibilityLabel("文件内容关键词")
                    .onSubmit(submitSearch)
                Button("搜索", action: submitSearch)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSearch)
            }
            if build != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text("正在读取文件 · 已检查 \(meter.bytes) 项")
                    }
                    Spacer()
                    Button("停止") { build?.cancel() }
                }.foregroundStyle(.secondary)
            } else if let coverage {
                HStack {
                    Text("已读取 \(coverage.files) 个文件 · \(coverage.partial) 项未完整读取")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu("索引设置") {
                        Button("重新读取文件", action: rebuild)
                        Button("删除本机索引", role: .destructive, action: deleteIndex)
                    }
                }.font(.caption)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if matches.isEmpty {
                if search != nil {
                    ProgressView("正在搜索…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "doc.text.magnifyingglass")
                    } description: {
                        if !submitted { Text("例如合同编号、文档标题或图片上的文字。第一次搜索会在本机读取文件。") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(matches) { match in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(match.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                            Text(match.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if match.page > 0 && match.url.pathExtension.lowercased() == "pdf" {
                                Button("预览此页") { selected = match }
                            }
                            Button("定位文件") {
                                workspace.presentedTool = nil
                                workspace.revealInFolder(match.url)
                            }
                        }.buttonStyle(.borderless)
                        Text(match.url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(match.url.path)
                        Text(match.excerpt).lineLimit(2).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }.listStyle(.inset)
                if matches.count == 200 {
                    Text("显示前 200 个匹配片段。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if root == nil {
                root = selectedFolder ?? workspace.directoryBrowser?.directory ?? workspace.activeProjectMemory?.root
            }
        }
        .task(id: root) {
            scopeReady = false
            search?.cancel()
            search = nil
            coverage = nil
            matches = []
            submitted = false
            issue = nil
            guard let index else { return }
            defer { if !Task.isCancelled { scopeReady = true } }
            do {
                let value = try await Task.detached(priority: .utility) { try index.coverage() }.value
                if !Task.isCancelled { coverage = value }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
        .onDisappear {
            build?.cancel()
            search?.cancel()
        }
        .sheet(item: $selected) { match in
            VStack(alignment: .trailing) {
                Button("关闭") { selected = nil }.keyboardShortcut(.cancelAction)
                IndexedPDFPage(url: match.url, pageNumber: match.page)
            }.padding().frame(width: 700, height: 540)
        }
    }

    private var emptyTitle: String {
        if root == nil { return "选择搜索的文件夹" }
        if issue != nil { return "搜索未完成" }
        return submitted ? "未找到匹配的文字" : "输入你记得的一段文字"
    }

    private var canSearch: Bool {
        root != nil && scopeReady && build == nil && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitSearch() {
        guard canSearch else { return }
        if coverage == nil { rebuild() }
        else { runSearch() }
    }

    private var index: ContentIndex? {
        root.map { ContentIndex(root: $0, storage: workspace.professional.storage,
                                includesDescendants: includesDescendants, showHidden: showHidden) }
    }

    private func rebuild() {
        guard let index, build == nil else { return }
        let progress = TransferMeter()
        meter = progress
        issue = nil
        build = Task {
            let worker = Task.detached(priority: .utility) { try index.rebuild(progress: progress) }
            defer { build = nil }
            do {
                coverage = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                 onCancel: { worker.cancel() })
                if !query.isEmpty { runSearch() }
            } catch is CancellationError {
                issue = "已停止更新。"
            } catch { issue = error.localizedDescription }
        }
    }

    private func runSearch() {
        guard let index, coverage != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        search?.cancel()
        let term = query
        submitted = true
        issue = nil
        search = Task {
            let worker = Task.detached(priority: .userInitiated) { try index.search(term) }
            do {
                let results = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                    onCancel: { worker.cancel() })
                if !Task.isCancelled { matches = results }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
            if !Task.isCancelled { search = nil }
        }
    }

    private func deleteIndex() {
        guard let index, build == nil else { return }
        search?.cancel()
        search = nil
        do {
            try index.delete()
            issue = nil
            coverage = nil
            matches = []
            submitted = false
        } catch { issue = error.localizedDescription }
    }
}

private struct IndexedPDFPage: NSViewRepresentable {
    let url: URL
    let pageNumber: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.autoScales = true
        let document = PDFDocument(url: url)
        view.document = document
        if let page = document?.page(at: pageNumber - 1) { view.go(to: page) }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}
