import SwiftUI

struct DeliveryView: View {
    let workspace: BrowserWorkspace
    @ViewState var files: [URL]
    @ViewState private var mode = Mode.prepare
    @ViewState private var template = DeliveryTemplate.presets[2]
    @ViewState private var destination: URL?
    @ViewState private var project = ""
    @ViewState private var archiveName = ""
    @ViewState private var plan: DeliveryPlan?
    @ViewState private var enabledRows: Set<URL> = []
    @ViewState private var selectedRecord: UUID?
    @ViewState private var issue: String?
    @ViewState private var verifiedRecord: UUID?

    private enum Mode: String, CaseIterable, Identifiable {
        case prepare = "准备交付", history = "交付历史"
        var id: Self { self }
    }

    private var history: DeliveryHistory { workspace.professional.history }
    private var running: Bool { history.isBuilding }
    private var rows: [DeliveryPlan.Row] { plan?.rows.filter { enabledRows.contains($0.id) } ?? [] }
    private var checks: [String] { plan == nil ? [] : DeliveryPlan.issues(in: rows, template: template) }
    private var cleanName: String {
        let name = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.lowercased().hasSuffix(".zip") ? String(name.dropLast(4)) : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("交付", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 255)
            if let issue = issue ?? history.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if mode == .prepare {
                prepare
            } else {
                records
            }
        }
        .onAppear {
            if project.isEmpty { project = workspace.activeProjectMemory?.name ?? workspace.activeBrowser.directoryName }
            if archiveName.isEmpty { archiveName = "\(project)-\(Date.now.formatted(.iso8601.year().month().day()))" }
            if destination == nil {
                destination = workspace.activeProjectMemory?.delivery
                if destination == nil, let browser = workspace.directoryBrowser, browser.canModifyDirectory {
                    destination = browser.directory
                }
            }
        }
        .task(id: files) { await scan(files) }
    }

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !files.isEmpty {
                HStack {
                    Button("更换交付文件…", action: chooseInputs)
                    Spacer()
                    Text("压缩包名称")
                    TextField("压缩包名称", text: $archiveName)
                        .labelsHidden().frame(maxWidth: 230)
                }
                LocalFolderField(title: "保存到", url: $destination)
                ruleSettings
            }
            if !checks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                            Label(check, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 64).font(.caption)
            }
            if let plan {
                if !plan.unavailable.isEmpty {
                    Text("\(plan.unavailable.count) 项无法纳入，将写入交付记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                List(plan.rows) { row in
                    Toggle(isOn: Binding(get: { enabledRows.contains(row.id) }, set: { included in
                        if included { enabledRows.insert(row.id) } else { enabledRows.remove(row.id) }
                    })) {
                        HStack {
                            Text(row.path).lineLimit(1).truncationMode(.middle).help(row.url.path)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: row.stamp.bytes, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .disabled(running)
            } else if files.isEmpty {
                ContentUnavailableView {
                    Label("选择要交付的文件或文件夹", systemImage: "shippingbox")
                } description: {
                    Text("生成一个 ZIP 和一份独立的校验文件。")
                } actions: {
                    Button("选择文件…", action: chooseInputs).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issue == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            HStack {
                if running { ProgressView().controlSize(.small) }
                if !files.isEmpty {
                    Text(prepareStatus ?? "将生成 ZIP 和校验文件").foregroundStyle(.secondary)
                    Spacer()
                    Button("生成交付包") { build() }
                        .buttonStyle(.borderedProminent)
                        .disabled(prepareStatus != nil)
                }
            }
        }
        .disabled(running)
    }

    private var ruleSettings: some View {
        DisclosureGroup("交付检查规则") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("模板", selection: $template.id) {
                    ForEach(DeliveryTemplate.presets + history.templates) { value in Text(value.title).tag(value.id) }
                }
                .onChange(of: template.id) { _, id in
                    if let saved = (DeliveryTemplate.presets + history.templates).first(where: { $0.id == id }) {
                        template = saved
                    }
                }
                TextField("必需格式", text: $template.required, prompt: Text("例如 pdf, png|jpg"))
                TextField("文件名正则表达式", text: $template.namePattern, prompt: Text("可留空"))
                HStack {
                    TextField("模板名称", text: $template.title).frame(maxWidth: 180)
                    Button("保存模板") {
                        var edited = template
                        if DeliveryTemplate.presets.contains(where: { $0.id == edited.id }) { edited.id = UUID().uuidString }
                        if history.saveTemplate(edited) { template = edited }
                    }
                }
                Text("逗号分隔必需格式组，竖线表示该组任意一种格式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
        }
    }

    private var prepareStatus: String? {
        if running { return "正在生成并校验交付包…" }
        if plan == nil { return issue == nil ? "正在读取文件…" : "交付文件读取失败" }
        if rows.isEmpty { return "请至少勾选一个文件" }
        if destination == nil { return "请选择保存位置" }
        if cleanName.isEmpty { return "请输入压缩包名称" }
        if !checks.isEmpty { return "请处理上方的检查结果" }
        return nil
    }

    @ViewBuilder private var records: some View {
        if history.records.isEmpty {
            ContentUnavailableView("暂无交付记录", systemImage: "clock")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 12) {
                List(history.records, selection: $selectedRecord) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.archive?.lastPathComponent ?? record.project).lineLimit(1)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(record.id)
                }.listStyle(.inset).frame(width: 245)
                if let record = history.records.first(where: { $0.id == selectedRecord }) {
                    recordDetails(record)
                } else {
                    ContentUnavailableView("选择一条记录", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func recordDetails(_ record: DeliveryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.template).font(.headline)
                Spacer()
                if let archive = record.archive {
                    Button("在文件列表查看") {
                        workspace.presentedTool = nil
                        workspace.revealInFolder(archive)
                    }
                    Button(verifiedRecord == record.id ? "校验通过 · 重新校验" : "重新校验") { verify(record) }
                }
            }
            if let failure = record.error { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            else if let hash = record.sha256 {
                Text("SHA-256 " + hash).font(.caption.monospaced()).textSelection(.enabled)
            }
            List {
                if let previous = history.previous(for: record), record.error == nil {
                    let changes = record.differences(from: previous)
                    Section("与上次交付相比") {
                        if changes.isEmpty { Text("内容一致").foregroundStyle(.secondary) }
                        ForEach(changes, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
                Section(record.error == nil ? "本次记录 \(record.entries.count) 项" : "传输未完成") {
                    ForEach(record.entries, id: \.path) { Text($0.path).textSelection(.enabled) }
                }
                if !record.skipped.isEmpty {
                    Section("此次跳过") { ForEach(Array(Set(record.skipped)).sorted(), id: \.self) { Text($0) } }
                }
            }.listStyle(.inset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseInputs() {
        let panel = NSOpenPanel()
        panel.directoryURL = workspace.directoryBrowser?.directory
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { files = panel.urls }
    }

    private func scan(_ urls: [URL]) async {
        plan = nil
        issue = nil
        enabledRows = []
        guard !urls.isEmpty else { return }
        do {
            let worker = Task.detached { try DeliveryPlan(items: urls) }
            let draft = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            plan = draft
            enabledRows = Set(draft.rows.map(\.id))
        } catch where !Task.isCancelled { issue = error.localizedDescription }
        catch {}
    }

    private func build() {
        guard let destination, !running else { return }
        history.isBuilding = true
        issue = nil
        let selected = rows
        let template = template
        let rejected = (plan?.unavailable ?? []) + (plan?.rows.filter { !enabledRows.contains($0.id) }.map(\.path) ?? [])
        let project = project
        let name = cleanName
        Task {
            defer { history.isBuilding = false }
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try DeliveryPackage.build(rows: selected, template: template, project: project,
                                              name: name, destination: destination, skipped: rejected)
                }.value
                history.append(record)
                selectedRecord = record.id
            } catch {
                let record = DeliveryRecord(id: UUID(), date: .now, project: project, template: template.title,
                    target: destination, archive: nil, sha256: nil, entries: [], skipped: rejected,
                    error: error.localizedDescription)
                history.append(record)
                selectedRecord = record.id
            }
            mode = .history
        }
    }

    private func verify(_ record: DeliveryRecord) {
        guard let archive = record.archive, let hash = record.sha256 else { return }
        Task {
            do {
                let valid = try await Task.detached {
                    guard let stamp = FileStamp(archive) else { throw CocoaError(.fileNoSuchFile) }
                    return try VerifiedFile.sha256(archive, stamp: stamp) == hash
                }.value
                issue = valid ? nil : "ZIP 校验值与交付记录不一致。"
                verifiedRecord = valid ? record.id : nil
            } catch { issue = error.localizedDescription }
        }
    }
}
