import SwiftUI

struct AgentConnectionsView: View {
    let service = AgentService.shared
    @ViewState private var workspaceID: UUID?
    @ViewState private var root: URL?
    @ViewState private var delivery: URL?
    @ViewState private var showsOptions = false
    @ViewState private var format: AgentService.Configuration = .codex
    @ViewState private var copied = false
    @ViewState private var copiedTest = false
    @ViewState private var issue: String?

    private let testPrompt = "请用 wfolder 搜索授权目录里最近七天修改的文件，并在 wfolder 中打开搜索结果。"
    private var codexConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    var body: some View {
        Form {
            if let grant = service.grant {
                connected(grant)
            } else {
                setup
            }
            if let details = issue ?? service.connectionIssue {
                Label(details, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 445)
        .onChange(of: format) { copied = false }
    }

    private var setup: some View {
        Section("授权文件夹") {
            Text("选择一个要交给 Agent 搜索的项目目录。直接选文件夹时，wfolder 会为它保存工作区。")
                .foregroundStyle(.secondary)
            if let root { path("所选目录", root) }
            HStack {
                Button(root == nil ? "选择文件夹…" : "更换文件夹…", action: chooseFolder)
                if !service.savedWorkspaces.isEmpty {
                    Menu("使用已有工作区") {
                        ForEach(service.savedWorkspaces) { saved in
                            Button(saved.name) { useWorkspace(saved) }
                        }
                    }
                }
            }
            if let chosen = service.savedWorkspaces.first(where: { $0.id == workspaceID }) {
                LabeledContent("工作区", value: chosen.name)
            }
            if root != nil {
                DisclosureGroup("交付目录（可选）", isExpanded: $showsOptions) {
                    LocalFolderField(title: "输出位置", url: $delivery)
                }
            }
            Button("授权并继续") {
                guard let root else { return }
                do {
                    try service.pair(workspaceID: workspaceID, root: root, delivery: delivery)
                    issue = nil
                } catch {
                    issue = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(root == nil)
        }
    }

    @ViewBuilder private func connected(_ grant: AgentGrant) -> some View {
        Section("当前授权") {
            if let saved = service.savedWorkspaces.first(where: { $0.id == grant.workspaceID }) {
                LabeledContent("工作区", value: saved.name)
            }
            path("文件夹", grant.root.url)
            if let delivery = grant.delivery { path("交付目录", delivery.url) }
            Button("撤销连接", role: .destructive) { revoke() }
        }
        Section("配置客户端") {
            Picker("客户端", selection: $format) {
                ForEach(AgentService.Configuration.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if format == .codex {
                Text("将配置粘贴到 ~/.codex/config.toml 并保存。已有 wfolder 配置时，替换原来的 wfolder 配置段。然后新建 Codex 对话。")
                    .foregroundStyle(.secondary)
            } else {
                Text("将 JSON 添加到客户端的 MCP 设置，再开始一个新对话。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(copied ? "已复制配置" : (format == .codex ? "复制 Codex 配置" : "复制 MCP JSON")) {
                    copied = service.copyConfiguration(format)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!service.listening)
                if format == .codex, FileManager.default.fileExists(atPath: codexConfig.path) {
                    Button("在访达中显示配置文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([codexConfig])
                    }
                }
                if !service.listening {
                    Button("重试连接") { service.retryConnection() }
                }
            }
            Text("配置包含连接凭据，请粘贴到客户端设置。使用时保持 wfolder 打开。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("试一次搜索") {
            Label(!service.hasReceivedRequest ? "等待客户端调用" : "已收到客户端调用",
                  systemImage: !service.hasReceivedRequest ? "circle.dotted" : "checkmark.circle.fill")
                .foregroundStyle(!service.hasReceivedRequest ? Color.secondary : Color.green)
            Text(testPrompt).textSelection(.enabled)
            HStack {
                Button(copiedTest ? "已复制测试指令" : "复制测试指令") {
                    NSPasteboard.general.clearContents()
                    copiedTest = NSPasteboard.general.setString(testPrompt, forType: .string)
                }
                Button("查看 Agent 任务") { service.present() }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 Agent 可以搜索的文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root ?? service.workspace?.directoryBrowser?.directory
        let select: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            root = url
            issue = nil
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: select) }
        else { panel.begin(completionHandler: select) }
    }

    private func useWorkspace(_ saved: NamedWorkspace) {
        let memory = service.workspace?.aiMemory.project(saved.id)
        workspaceID = saved.id
        root = memory?.root ?? saved.tab.preferredFolder
        delivery = memory?.delivery
        showsOptions = delivery != nil
        issue = root == nil ? "这个工作区需要先选择授权目录。" : nil
    }

    private func path(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            Text(url.path).lineLimit(1).truncationMode(.middle).help(url.path).textSelection(.enabled)
        }
    }

    private func revoke() {
        service.revoke()
        copied = false
        copiedTest = false
        workspaceID = nil
        root = nil
        delivery = nil
        showsOptions = false
        issue = nil
    }
}

struct AgentTasksView: View {
    let service = AgentService.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agent 任务").font(.headline)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if service.jobs.isEmpty {
                ContentUnavailableView("暂无 Agent 任务", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    @Bindable var service = service
                    List(service.jobs, selection: $service.focusedJob) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.workflow.name).lineLimit(1)
                            Text(job.status.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(job.id)
                    }
                    .listStyle(.sidebar)
                    .frame(width: 180)
                    Divider()
                    if let job = service.jobs.first(where: { $0.id == service.focusedJob }) {
                        JobReview(job: job, service: service, close: close)
                    } else {
                        ContentUnavailableView("选择要查看的任务", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: 720, height: 455)
        .onAppear {
            if service.focusedJob == nil { service.focusedJob = service.jobs.first?.id }
        }
    }
}

private struct JobReview: View {
    let job: AgentJob
    let service: AgentService
    let close: () -> Void

    private var canEdit: Bool { job.status == .preparing || job.status == .awaiting_approval }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.workflow.name).font(.headline)
            Text(job.workflow.details).foregroundStyle(.secondary).font(.callout)
            if let destination = job.plan?.destination {
                LabeledContent("目标目录", value: destination.path).font(.caption).textSelection(.enabled)
            }
            if let archive = job.plan?.archiveDirectory {
                LabeledContent("ZIP 生成目录", value: archive.path).font(.caption).textSelection(.enabled)
            }
            if canEdit && !job.predictedConflicts.isEmpty {
                let names = job.predictedConflicts.joined(separator: "、")
                Label("目标目录已有同名项目：" + names, systemImage: "exclamationmark.circle")
                    .font(.caption).lineLimit(2).help(names)
            }
            if let issue = job.issue { Text(issue).foregroundStyle(.red).font(.callout) }
            if !job.warnings.isEmpty {
                Text(job.warnings.joined(separator: "\n")).font(.callout).foregroundStyle(.secondary)
            }
            List {
                Section(canEdit ? "参与流程的文件" : "来源文件") {
                    ForEach(job.inputs) { input in
                        Toggle(isOn: Binding(get: { job.selected.contains(input.id) }, set: {
                            service.toggle(input, in: job, enabled: $0)
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(input.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                if let rename = job.plan?.rename?.rows.first(where: { $0.source == input.url }), rename.changed {
                                    Text("→ " + rename.proposed).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .help(input.url.path)
                        }
                        .disabled(!canEdit)
                    }
                }
                if !job.outputURLs.isEmpty {
                    Section("实际输出") {
                        ForEach(job.outputURLs, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                close()
                                service.workspace?.revealInFolder(url)
                            }
                            .buttonStyle(.borderless)
                            .help(url.path)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                if job.status == .preparing || job.status == .running { ProgressView().controlSize(.small) }
                Text(job.status.title).foregroundStyle(.secondary)
                Spacer()
                if canEdit {
                    Button("拒绝任务", role: .destructive) { service.cancel(job) }
                    Button("确认并执行") { service.approve(job) }
                        .buttonStyle(.borderedProminent)
                        .disabled(job.status != .awaiting_approval || job.plan == nil)
                } else if job.status == .transferring {
                    Button("查看传输队列") {
                        close()
                        service.workspace?.revealOperations(.transfers)
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
