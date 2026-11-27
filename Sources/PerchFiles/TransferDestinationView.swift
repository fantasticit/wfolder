import SwiftUI

struct TransferDestinationRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let operation: PaneTransferOperation
    let base: URL
    let fromStash: Bool
}

struct TransferDestinationView: View {
    let request: TransferDestinationRequest
    let workspace: BrowserWorkspace
    @ViewState private var path = ""
    @ViewState private var resolving = false
    @ViewState private var issue: String?
    @ViewState private var savesWorkflow = false
    @ViewState private var workflowName = ""
    @FocusState private var pathFocused: Bool

    private var groups: [(String, [URL])] {
        var seen = Set<String>()
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file://") ? "" : trimmed
        return [("工作区交付目录", workspace.activeProjectMemory?.delivery.map { [$0] } ?? []),
                ("收藏", workspace.quickAccessPins.filter(\.isFolder).map(\.url)),
                ("最近的目标目录", workspace.recentDestinations),
                ("已打开的面板", workspace.folderBrowsers.map(\.directory)),
                ("常用位置", BrowserModel.defaults.map(\.url))].map { name, urls in
            (name, urls.filter { url in
                (filter.isEmpty || url.path.localizedStandardContains(filter) ||
                    displayName(for: url).localizedStandardContains(filter)) &&
                    seen.insert(url.path).inserted
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(request.operation.title)到文件夹").font(.headline)
            Text("\(request.urls.count) 个项目").font(.caption).foregroundStyle(.secondary)
            TextField("输入路径或筛选目录", text: $path)
                .textFieldStyle(.roundedBorder)
                .focused($pathFocused)
                .onChange(of: path) { issue = nil }
                .onSubmit(submit)
            List {
                ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { name, urls in
                    Section(name) {
                        ForEach(urls, id: \.path) { url in
                            Button { path = url.path } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(for: url)).lineLimit(1)
                                        Text(url.path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    if path == url.path {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(url.path)
                        }
                    }
                }
            }
            .frame(minHeight: 205, idealHeight: 285)
            Toggle("同时保存为文件流程", isOn: $savesWorkflow)
            if savesWorkflow {
                TextField("流程名称", text: $workflowName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: workflowName) { issue = nil }
            }
            if let issue { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { workspace.destinationRequest = nil }.keyboardShortcut(.cancelAction)
                Button(request.operation.title, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolving || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 510)
        .task { pathFocused = true }
    }

    private func displayName(for url: URL) -> String {
        if url.path == "/" { return "磁盘" }
        return BrowserModel.defaults.first(where: { $0.url.path == url.path })?.name ?? url.lastPathComponent
    }

    private func submit() {
        let input = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !resolving else { return }
        resolving = true
        let base = request.base
        Task {
            defer { resolving = false }
            let address = await Task.detached { BrowserAddress.resolve(input, relativeTo: base) }.value
            guard workspace.destinationRequest?.id == request.id else { return }
            guard case .folder(let directory) = address else {
                issue = "找不到目标文件夹。"
                return
            }
            if request.operation == .move,
               request.urls.allSatisfy({ $0.deletingLastPathComponent().path == directory.path }) {
                issue = "所选项目已在该文件夹。"
                return
            }
            if savesWorkflow {
                let name = workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
                let workflow = FileWorkflow(name: name, transfer: request.operation == .copy ? .copy : .move,
                                            destination: directory)
                guard workflow.isValid, workspace.aiMemory.save(workflow) else {
                    issue = "请输入唯一的流程名称，最多 80 个字符。"
                    return
                }
            }
            if workspace.transfer(request.urls, into: directory, operation: request.operation, fromStash: request.fromStash) {
                workspace.destinationRequest = nil
            }
        }
    }
}
