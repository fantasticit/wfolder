import SwiftUI

struct BatchRenameRule: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case replace = "替换文字", prefix = "添加前缀", sequence = "顺序编号", modifiedDate = "修改日期前缀"
        var id: Self { self }
    }

    var style: Style = .prefix
    var text = ""
    var replacement = ""
    var start = "1"

    func proposedName(for entry: FileEntry, at index: Int) -> String {
        let fileExtension = entry.isFolder ? "" : entry.url.pathExtension
        let stem = fileExtension.isEmpty ? entry.filename : (entry.filename as NSString).deletingPathExtension
        let newName: String
        switch style {
        case .replace:
            guard !text.isEmpty else { return entry.filename }
            newName = stem.replacingOccurrences(of: text, with: replacement)
        case .prefix:
            newName = text + stem
        case .sequence:
            guard let first = Int(start), (0...999_999_999).contains(first) else { return "" }
            newName = text + String(format: "%03d", first + index)
        case .modifiedDate:
            guard let modified = entry.modified else { return "" }
            let date = modified.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            newName = date + "_" + stem
        }
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return fileExtension.isEmpty ? newName : newName + "." + fileExtension
    }
}

struct BatchRenamePlan: Sendable {
    struct Row: Identifiable, Sendable {
        let source: URL
        let proposed: String
        var issue: String?
        var id: URL { source }
        var changed: Bool { !source.lastPathComponent.utf8.elementsEqual(proposed.utf8) }
    }

    let rows: [Row]
    var canApply: Bool { rows.contains(where: \.changed) && rows.allSatisfy { $0.issue == nil } }

    init(items: [FileEntry], rule: BatchRenameRule) throws {
        var rows = items.enumerated().map { index, entry in
            Row(source: entry.url, proposed: rule.proposedName(for: entry, at: index))
        }
        let paths = rows.map(\.source)
        let roots = Set(FileSystem.selectedRoots(paths))
        let byParent = Dictionary(grouping: rows.indices) { rows[$0].source.deletingLastPathComponent().resolvingSymlinksInPath() }

        for (directory, indexes) in byParent {
            try Task.checkCancellation()
            let volume = try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            let sensitive = volume?.volumeSupportsCaseSensitiveNames ?? false
            func key(_ name: String) -> String {
                let normalized = name.precomposedStringWithCanonicalMapping
                return sensitive ? normalized : normalized.lowercased()
            }
            let existing = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).map(key))
            let selected = Set(indexes.map { key(rows[$0].source.lastPathComponent) })
            let occupied = existing.subtracting(selected)
            let proposed = Dictionary(grouping: indexes) { key(rows[$0].proposed) }
            for index in indexes {
                let name = rows[index].proposed
                if !roots.contains(rows[index].source) { rows[index].issue = "同时选中了上级文件夹" }
                else if (try? FileSystem.validateName(name)) == nil { rows[index].issue = "名称无效" }
                else if occupied.contains(key(name)) { rows[index].issue = "目录中已有同名项目" }
                else if (proposed[key(name)]?.count ?? 0) > 1 { rows[index].issue = "新名称重复" }
            }
        }
        self.rows = rows
    }

    func apply() throws -> FileOperationResult {
        guard canApply else { throw BatchRenameError.conflicts }
        let pairs = rows.filter(\.changed).map { row in
            (row.source, row.source.deletingLastPathComponent().appendingPathComponent(row.proposed))
        }
        try FileSystem.relocateGroup(pairs)
        return FileOperationResult(revealed: pairs.map { $0.1 }, relocations: pairs.map {
            FileRelocation(original: $0.0, current: $0.1)
        })
    }
}

extension FileSystem {
    static func relocateGroup(_ pairs: [(URL, URL)]) throws {
        struct Change {
            let original: URL
            let temporary: URL
            let target: URL
        }
        let changes = pairs.map { source, target in
            let temporary = source.deletingLastPathComponent().appendingPathComponent(".wfolder-" + UUID().uuidString)
            return Change(original: source, temporary: temporary, target: target)
        }
        var staged: [Change] = []
        var finished: [Change] = []
        do {
            for change in changes {
                try moveExclusive(from: change.original, to: change.temporary)
                staged.append(change)
            }
            for change in staged {
                try moveExclusive(from: change.temporary, to: change.target)
                finished.append(change)
            }
        } catch {
            var lost: [String] = []
            for change in finished.reversed() {
                do { try moveExclusive(from: change.target, to: change.temporary) }
                catch { lost.append(change.target.path) }
            }
            let stillAtTarget = Set(lost)
            for change in staged.reversed() where !stillAtTarget.contains(change.target.path) {
                do { try moveExclusive(from: change.temporary, to: change.original) }
                catch { lost.append(change.temporary.path) }
            }
            if !lost.isEmpty { throw BatchRenameError.rollback(lost) }
            throw error
        }
    }
}

private enum BatchRenameError: LocalizedError {
    case conflicts, rollback([String])
    var errorDescription: String? {
        switch self {
        case .conflicts: return "名称有冲突，或没有需要改名的项目。"
        case .rollback(let paths): return "部分项目未能恢复原名，请检查以下位置。\n" + paths.joined(separator: "\n")
        }
    }
}

struct BatchRenameView: View {
    let browser: BrowserModel
    let entries: [FileEntry]
    var saveWorkflow: ((BatchRenameRule) -> Void)? = nil
    let close: () -> Void
    @ViewState private var rule = BatchRenameRule()
    @ViewState private var plan: BatchRenamePlan?
    @ViewState private var checkedRule: BatchRenameRule?
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量重命名").font(.headline)
            Picker("规则", selection: $rule.style) {
                ForEach(BatchRenameRule.Style.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                if rule.style != .modifiedDate {
                    TextField(rule.style == .replace ? "查找文字" : "前缀", text: $rule.text)
                }
                if rule.style == .replace { TextField("替换为", text: $rule.replacement) }
                if rule.style == .sequence { TextField("起始编号", text: $rule.start).frame(width: 120) }
            }
            HStack {
                Text("原名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("新名称").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let plan, checkedRule == rule {
                List(plan.rows) { row in
                    HStack(alignment: .top) {
                        Text(row.source.lastPathComponent).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.proposed).lineLimit(1)
                            if let issue = row.issue { Text(issue).font(.caption).foregroundStyle(.red) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(row.source.path)
                }
            } else if let error, checkedRule == rule {
                Text(error).foregroundStyle(.red).frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                if let saveWorkflow {
                    Button("保存为流程…") { saveWorkflow(rule) }
                        .disabled(plan?.canApply != true || checkedRule != rule)
                }
                Button("应用重命名") {
                    browser.batchRename(entries, rule: rule)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.canApply != true || checkedRule != rule || !browser.canModifyDirectory)
            }
        }
        .padding(18)
        .frame(width: 620, height: 405)
        .task(id: rule) {
            let current = rule
            let items = entries
            do {
                try await Task.sleep(for: .milliseconds(100))
                let worker = Task.detached { try BatchRenamePlan(items: items, rule: current) }
                let result = await withTaskCancellationHandler {
                    await worker.result
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                checkedRule = current
                plan = try result.get()
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                plan = nil
                self.error = error.localizedDescription
            }
        }
    }
}
