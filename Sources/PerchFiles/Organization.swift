import SwiftUI

struct OrganizationRule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var source: URL
    var destination: URL
    var conditions = SearchConditions()
    var renaming = false
    var rename = BatchRenameRule()
    var groupsByKind: Bool?
}

struct OrganizationPlan: Sendable {
    struct Row: Identifiable, Sendable {
        let source: URL
        let stamp: FileStamp?
        let name: String
        let group: String
        var issue: String?
        var id: URL { source }
        var targetName: String { group.isEmpty ? name : group + "/" + name }
    }

    private struct Target: Sendable {
        let url: URL
        let existing: TransferFiles.Destination?
        let names: Set<String>
        let issue: String?

        init(group: String, base: TransferFiles.Destination) {
            url = group.isEmpty ? base.url : base.physical.appendingPathComponent(group, isDirectory: true)
            if !group.isEmpty, FileStamp(url) == nil {
                existing = nil
                names = []
                issue = nil
                return
            }
            let folder = group.isEmpty ? base : (FileStamp(url)?.directory == true ? try? TransferFiles.Destination(url) : nil)
            if let folder,
               let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.physical.path) {
                existing = folder
                names = Set(entries.map(folder.key))
                issue = nil
            } else {
                existing = nil
                names = []
                issue = "目标分类文件夹不可用"
            }
        }
    }

    let rule: OrganizationRule
    let destination: TransferFiles.Destination
    let rows: [Row]
    let unreadable: Int
    private let targets: [String: Target]

    init(rule: OrganizationRule, entries: [FileEntry], unreadable: Int) throws {
        self.rule = rule
        self.destination = try TransferFiles.Destination(rule.destination)
        self.unreadable = unreadable
        let destination = self.destination
        let sorted = entries.filter { !$0.isFolder }.sorted { $0.url.path < $1.url.path }
        let grouped = sorted.map { rule.groupsByKind == true ? Self.category(of: $0) : "" }
        let targets = Dictionary(uniqueKeysWithValues: Set(grouped).map { ($0, Target(group: $0, base: destination)) })
        self.targets = targets
        var rows = try zip(sorted, grouped).enumerated().map { index, item in
            try Task.checkCancellation()
            let (file, group) = item
            let target = targets[group]!
            let name = rule.renaming ? rule.rename.proposedName(for: file, at: index) : file.filename
            let stamp = FileStamp(file.url)
            var issue: String?
            if stamp?.regular != true { issue = "只整理普通文件" }
            else if (try? FileSystem.validateName(name)) == nil { issue = "名称无效" }
            else if let blocked = target.issue { issue = blocked }
            else if name == file.filename, target.existing.map({
                FileSystem.physicalDirectory(file.url.deletingLastPathComponent()).path == $0.physical.path
            }) == true {
                issue = "项目已在目标文件夹"
            } else if target.names.contains((target.existing ?? destination).key(name)) { issue = "目标处已有同名文件" }
            return Row(source: file.url, stamp: stamp, name: name, group: group, issue: issue)
        }
        let duplicates = Dictionary(grouping: rows.indices.filter { rows[$0].issue == nil }) {
            let row = rows[$0]
            let folder = targets[row.group]?.existing ?? destination
            return row.group + "/" + folder.key(row.name)
        }
        for indexes in duplicates.values where indexes.count > 1 {
            for index in indexes { rows[index].issue = "整理后的名称重复" }
        }
        self.rows = rows
    }

    var actionableCount: Int { rows.count(where: { $0.issue == nil }) }

    @MainActor static func prepare(_ rule: OrganizationRule, showHidden: Bool) async throws -> Self {
        let found = try await SmartFolder(name: rule.name, root: rule.source, conditions: rule.conditions)
            .results(showHidden: showHidden)
        let worker = Task.detached {
            try Self(rule: rule, entries: found.entries, unreadable: found.unreadable)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func run(scope: AIAutomationScope? = nil) -> FileOperationResult {
        var result = FileOperationResult()
        var prepared = targets.compactMapValues(\.existing)
        for row in rows where row.issue == nil {
            if Task.isCancelled { break }
            guard let stamp = row.stamp, let target = targets[row.group] else { continue }
            if let scope, !scope.permits(rule.source) || !scope.permits(destination.url) {
                result.failures.append(.init(source: row.source, message: "来源或目标的自动整理权限已变更。"))
                break
            }
            do {
                try destination.validate()
                if let scope, !scope.permits(row.source.deletingLastPathComponent()) {
                    result.failures.append(.init(source: row.source, message: "来源不在获准的文件夹内。"))
                    continue
                }
                let folder: TransferFiles.Destination
                if let existing = prepared[row.group] {
                    folder = existing
                } else {
                    guard FileStamp(target.url) == nil else { throw TransferFileError.changedFolder }
                    try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: false)
                    folder = try TransferFiles.Destination(target.url)
                    guard folder.physical.deletingLastPathComponent().path == destination.physical.path else {
                        throw TransferFileError.changedFolder
                    }
                    prepared[row.group] = folder
                }
                if let scope, !scope.permits(folder.url) {
                    result.failures.append(.init(source: row.source, message: "目标不在获准的文件夹内。"))
                    continue
                }
                let move = try TransferFiles.apply(row.source, stamp: stamp, into: folder, name: row.name,
                                                   operation: .move)
                if let warning = move.warning {
                    result.failures.append(.init(source: row.source, message: warning))
                }
                result.revealed.append(move.url)
                if !FileManager.default.fileExists(atPath: row.source.path) {
                    result.relocations.append(FileRelocation(original: row.source, current: move.url))
                }
            } catch is CancellationError {
                break
            } catch {
                result.failures.append(.init(source: row.source, message: error.localizedDescription))
            }
        }
        return result
    }

    private static func category(of file: FileEntry) -> String {
        if SearchFileKind.image.matches(file) { return "图片" }
        if SearchFileKind.video.matches(file) { return "视频" }
        if SearchFileKind.audio.matches(file) { return "音频" }
        if SearchFileKind.document.matches(file) { return "文档" }
        if SearchFileKind.archive.matches(file) { return "压缩包" }
        if ["dmg", "pkg", "iso"].contains(file.url.pathExtension.lowercased()) { return "安装包" }
        return "其他"
    }
}

struct OrganizationView: View {
    let workspace: BrowserWorkspace
    @ViewState private var rule: OrganizationRule
    @ViewState private var plan: OrganizationPlan?
    @ViewState private var request = 0
    @ViewState private var busy = false
    @ViewState private var applying = false
    @ViewState private var message: String?

    init(workspace: BrowserWorkspace, draft: OrganizationRule? = nil) {
        self.workspace = workspace
        let folder = workspace.activeBrowser.directory
        _rule = State(initialValue: draft ?? OrganizationRule(source: folder, destination: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("整理规则名称", text: $rule.name)
                Menu("已保存规则") {
                    ForEach(workspace.organizationRules) { saved in
                        Button(saved.name) { rule = saved }
                    }
                    if workspace.organizationRules.contains(where: { $0.id == rule.id }) {
                        Divider()
                        Button("移除此规则", role: .destructive) { workspace.removeOrganizationRule(rule) }
                    }
                    Button("新建规则") {
                        let origin = workspace.activeBrowser.directory
                        rule = OrganizationRule(source: origin, destination: origin)
                    }
                }
                Button("保存规则") { workspace.saveOrganizationRule(rule) }
                    .disabled(rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !rule.conditions.valid)
            }
            Group {
                folderRow("来源", folder: $rule.source)
                folderRow("归档到", folder: $rule.destination)
                SearchConditionFields(conditions: $rule.conditions)
                Toggle("按文件类型分到子文件夹", isOn: Binding(
                    get: { rule.groupsByKind == true }, set: { rule.groupsByKind = $0 }
                ))
                Toggle("移动时批量重命名", isOn: $rule.renaming)
                if rule.renaming { renameFields }
            }
            .disabled(applying)
            Divider()
            if busy {
                ProgressView("正在生成整理预览…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan, plan.rule == rule {
                List(plan.rows) { row in
                    HStack {
                        Text(row.source.lastPathComponent).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(row.targetName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if let issue = row.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                    }
                    .help(row.source.path)
                }
                Text("\(plan.actionableCount) 可移动 · \(plan.rows.count - plan.actionableCount) 跳过" +
                     (plan.unreadable == 0 ? "" : " · \(plan.unreadable) 个子目录无法读取"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("预览要整理的文件", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message { Text(message).font(.caption).lineLimit(4).textSelection(.enabled) }
            HStack {
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                Button("预览整理") { request += 1 }.disabled(!rule.conditions.valid || applying || busy)
                Button("移动 \(plan?.actionableCount ?? 0) 项", action: apply)
                    .disabled(plan?.rule != rule || plan?.actionableCount == 0 || applying || busy)
            }
        }
        .padding(18)
        .frame(width: 680, height: 580)
        .interactiveDismissDisabled(applying)
        .onChange(of: rule) { plan = nil; message = nil }
        .task(id: request) { if request > 0 { await prepare() } }
    }

    private func folderRow(_ title: String, folder: Binding<URL>) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Text(folder.wrappedValue.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            DirectoryChooser(title: "选取…", directory: folder)
        }
    }

    private var renameFields: some View {
        HStack {
            Picker("规则", selection: $rule.rename.style) {
                ForEach(BatchRenameRule.Style.allCases) { Text($0.rawValue).tag($0) }
            }.fixedSize()
            if rule.rename.style != .modifiedDate {
                TextField(rule.rename.style == .replace ? "查找文字" : "前缀", text: $rule.rename.text)
            }
            if rule.rename.style == .replace { TextField("替换为", text: $rule.rename.replacement) }
            if rule.rename.style == .sequence { TextField("起始编号", text: $rule.rename.start).frame(width: 100) }
        }
    }

    private func prepare() async {
        busy = true
        plan = nil
        message = nil
        defer { busy = false }
        let current = rule
        do {
            let candidate = try await OrganizationPlan.prepare(current, showHidden: workspace.showHidden)
            if !Task.isCancelled, rule == current { plan = candidate }
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    private func apply() {
        guard let plan, plan.rule == rule else { return }
        applying = true
        Task {
            defer { applying = false }
            guard let result = await workspace.applyOrganization(plan) else {
                message = "请等待当前文件操作完成。"
                return
            }
            self.plan = nil
            message = "已移动 \(result.relocations.count) 项" +
                (result.failures.isEmpty ? "" : "\n" + result.failureSummary)
        }
    }
}
