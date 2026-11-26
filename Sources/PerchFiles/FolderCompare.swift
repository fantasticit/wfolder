import SwiftUI

enum FolderCopyDirection: String, CaseIterable, Identifiable, Sendable {
    case leftToRight = "左侧 → 右侧", rightToLeft = "右侧 → 左侧"
    var id: Self { self }
}

struct DirectoryPair: Codable, Equatable, Sendable {
    let left: URL
    let right: URL
    let linked: Bool

    func target(for directory: URL, from source: URL, to destination: URL) -> URL? {
        let path = directory.standardizedFileURL.path
        let root = source.standardizedFileURL.path
        if path == root { return destination }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = String(path.dropFirst(prefix.count))
        return destination.appendingPathComponent(suffix, isDirectory: true)
    }
}

struct FolderComparison: Sendable {
    struct Item: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case folder, file, link, other }
        let url: URL
        let kind: Kind
        let size: Int?
        let modified: Date?
        let number: UInt64?

        init(_ url: URL) throws {
            let fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
            let info = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                          .fileSizeKey, .contentModificationDateKey])
            self.url = url
            if info.isSymbolicLink == true { kind = .link }
            else if info.isDirectory == true { kind = .folder }
            else if info.isRegularFile == true { kind = .file }
            else { kind = .other }
            size = info.fileSize
            modified = info.contentModificationDate
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }

    struct Difference: Identifiable, Sendable {
        let path: String
        let left: Item?
        let right: Item?
        var id: String { path }

        var status: String {
            guard let left, let right else { return left == nil ? "右侧独有" : "左侧独有" }
            return left.kind == right.kind ? "内容不同" : "类型不同"
        }

        func sides(_ direction: FolderCopyDirection) -> (source: Item?, target: Item?) {
            direction == .leftToRight ? (left, right) : (right, left)
        }

        func planLabel(_ direction: FolderCopyDirection, includeNewer: Bool) -> String {
            let (source, target) = sides(direction)
            guard source != nil else { return "仅目标有 · 保留" }
            if shouldSync(direction, includeNewer: includeNewer) { return target == nil ? "新增" : "更新" }
            return "冲突 · 保留"
        }

        func shouldSync(_ direction: FolderCopyDirection, includeNewer: Bool) -> Bool {
            let (source, target) = sides(direction)
            guard let source, source.kind != .other else { return false }
            guard let target else { return true }
            guard includeNewer, source.kind == .file, target.kind == .file,
                  let updated = source.modified, let previous = target.modified else { return false }
            return updated > previous
        }
    }

    let left: URL
    let right: URL
    let differences: [Difference]

    init(left: URL, right: URL, showHidden: Bool) throws {
        let left = FileSystem.physicalDirectory(left)
        let right = FileSystem.physicalDirectory(right)
        guard left.path != right.path, !Self.contains(left, right), !Self.contains(right, left) else {
            throw CompareError.overlapping
        }
        self.left = left
        self.right = right
        let a = try Self.scan(left, showHidden: showHidden)
        let b = try Self.scan(right, showHidden: showHidden)
        let keys = Set(a.keys).union(b.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var differences: [Difference] = []
        for path in keys {
            try Task.checkCancellation()
            let difference = Difference(path: path, left: a[path], right: b[path])
            if let x = difference.left, let y = difference.right, try Self.same(x, y) { continue }
            differences.append(difference)
        }
        self.differences = differences
    }

    func copy(_ selected: Set<String>, direction: FolderCopyDirection, updating: Bool) -> FileOperationResult {
        let targetRoot = direction == .leftToRight ? right : left
        let choices = differences.filter { selected.contains($0.id) && $0.sides(direction).source != nil }
        let selectedFolders = Set(choices.compactMap { item in
            let (source, target) = item.sides(direction)
            return source?.kind == .folder && target == nil ? item.path : nil
        })
        let filtered = updating ? choices.sorted {
            $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
        } : choices.filter { item in
            var parent = (item.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if selectedFolders.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }

        var result = FileOperationResult()
        for row in filtered {
            guard let source = row.sides(direction).source else { continue }
            do {
                guard try Item(source.url) == source else { throw CompareError.changed }
                let parent = try Self.makeParents(for: row.path, inside: targetRoot)
                let existing = row.sides(direction).target
                if updating, let existing {
                    guard row.shouldSync(direction, includeNewer: true), try Item(existing.url) == existing else {
                        throw CompareError.changed
                    }
                    try Self.replace(source.url, existing: existing, in: parent)
                    result.revealed.append(existing.url)
                } else if updating && source.kind == .folder {
                    let target = parent.appendingPathComponent(source.url.lastPathComponent, isDirectory: true)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    result.revealed.append(target)
                } else {
                    let destination: URL
                    do {
                        destination = try FileSystem.paste(source.url, into: parent, move: false)
                    } catch where FileSystem.isNameConflict(error) && !updating {
                        destination = try FileSystem.copyWithAvailableName(FileEntry.read(source.url), into: parent, move: false)
                    }
                    result.revealed.append(destination)
                }
            } catch {
                result.failures.append(.init(source: source.url, message: error.localizedDescription))
            }
        }
        return result
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }

    private static func scan(_ root: URL, showHidden: Bool) throws -> [String: Item] {
        var scanError: Error?
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: options,
            errorHandler: { _, error in scanError = error; return false }) else { throw CompareError.unreadable }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        var items: [String: Item] = [:]
        for case let url as URL in iterator {
            try Task.checkCancellation()
            guard url.path.hasPrefix(prefix) else { continue }
            items[String(url.path.dropFirst(prefix.count))] = try Item(url)
        }
        if let scanError { throw scanError }
        return items
    }

    private static func same(_ first: Item, _ second: Item) throws -> Bool {
        guard first.kind == second.kind else { return false }
        let fm = FileManager.default
        switch first.kind {
        case .folder: return true
        case .other: return false
        case .link:
            return try fm.destinationOfSymbolicLink(atPath: first.url.path) ==
                fm.destinationOfSymbolicLink(atPath: second.url.path)
        case .file:
            guard first.size == second.size else { return false }
            let a = try FileHandle(forReadingFrom: first.url)
            defer { try? a.close() }
            let b = try FileHandle(forReadingFrom: second.url)
            defer { try? b.close() }
            while true {
                try Task.checkCancellation()
                let one = try a.read(upToCount: 256 * 1024) ?? Data()
                let two = try b.read(upToCount: 256 * 1024) ?? Data()
                if one != two { return false }
                if one.isEmpty { return true }
            }
        }
    }

    private static func makeParents(for path: String, inside root: URL) throws -> URL {
        let fm = FileManager.default
        guard FileSystem.physicalDirectory(root).path == root.path else { throw CompareError.unsafeFolder }
        var folder = root
        for part in path.split(separator: "/").dropLast() {
            folder.appendPathComponent(String(part), isDirectory: true)
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            guard try Item(folder).kind == .folder else { throw CompareError.unsafeFolder }
        }
        return folder
    }

    private static func replace(_ source: URL, existing: Item, in parent: URL) throws {
        let temporary = parent.appendingPathComponent(".wfolder-sync-" + UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        guard try Item(existing.url) == existing else { throw CompareError.changed }
        let status = temporary.withUnsafeFileSystemRepresentation { temporaryPath in
            existing.url.withUnsafeFileSystemRepresentation { existingPath in
                renameatx_np(AT_FDCWD, temporaryPath, AT_FDCWD, existingPath, UInt32(RENAME_SWAP))
            }
        }
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

private enum CompareError: LocalizedError {
    case overlapping, unreadable, changed, unsafeFolder
    var errorDescription: String? {
        switch self {
        case .overlapping: return "请选取两个独立目录。同步不适用于同一目录或互为上下级的目录。"
        case .unreadable: return "无法读取所选目录。"
        case .changed: return "文件在对比后发生了变化，请重新对比。"
        case .unsafeFolder: return "目标路径包含符号链接或同名文件。"
        }
    }
}

struct FolderCompareView: View {
    let workspace: BrowserWorkspace
    @ViewState private var left: UUID?
    @ViewState private var right: UUID?
    @ViewState private var comparing = false
    @ViewState private var applying = false
    @ViewState private var comparison: FolderComparison?
    @ViewState private var selection: Set<String> = []
    @ViewState private var direction = FolderCopyDirection.leftToRight
    @ViewState private var includeNewer = false
    @ViewState private var confirmSync = false
    @ViewState private var request = 0
    @ViewState private var message: String?
    @ViewState private var linked = false
    @ViewState private var leftPreview: FileEntry?
    @ViewState private var rightPreview: FileEntry?

    private var inspected: FolderComparison.Difference? {
        guard selection.count == 1, let path = selection.first else { return nil }
        return comparison?.differences.first { $0.id == path }
    }

    private var panes: [BrowserModel] { workspace.folderBrowsers }
    private var syncPaths: Set<String> {
        Set(comparison?.differences.filter { $0.shouldSync(direction, includeNewer: includeNewer) }.map(\.id) ?? [])
    }
    private var canCopy: Bool {
        comparison?.differences.contains { selection.contains($0.id) && $0.sides(direction).source != nil } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("对比面板目录").font(.headline)
            HStack {
                choice("左侧", selection: $left)
                choice("右侧", selection: $right)
                Button("对比") { request += 1 }.disabled(left == nil || right == nil || left == right || comparing || applying)
                Spacer()
                Toggle("联动导航", isOn: $linked)
                    .onChange(of: linked) { savePair() }
                Button("保存目录对", action: savePair).disabled(left == nil || right == nil || left == right)
            }
            if comparing {
                ProgressView("正在比较文件内容…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let comparison, !comparison.differences.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("同步计划").font(.subheadline.weight(.semibold))
                        List(comparison.differences, selection: $selection) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.path).lineLimit(1).truncationMode(.middle)
                                Text(row.planLabel(direction, includeNewer: includeNewer))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(row.id)
                            .help(row.path + " · " + row.status)
                        }
                    }
                    .frame(width: 250)
                    Divider()
                    counterpart("左侧", entry: leftPreview)
                    Divider()
                    counterpart("右侧", entry: rightPreview)
                }
            } else {
                ContentUnavailableView(comparison == nil ? "选择两个目录开始对比" : "目录内容一致",
                                       systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message { Text(message).font(.caption).textSelection(.enabled).lineLimit(4) }
            HStack {
                Picker("方向", selection: $direction) {
                    ForEach(FolderCopyDirection.allCases) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Toggle("同步时更新较旧文件", isOn: $includeNewer)
                Spacer()
                Button("复制选中") { apply(selection, sync: false) }.disabled(!canCopy || applying || comparing)
                Button("按规则同步…") { confirmSync = true }.disabled(syncPaths.isEmpty || applying || comparing)
            }
            HStack {
                if applying { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction).disabled(applying)
            }
        }
        .padding(18)
        .frame(minWidth: 855, idealWidth: 1040, minHeight: 490, idealHeight: 600)
        .interactiveDismissDisabled(applying)
        .onAppear {
            let pair = workspace.activeTab.comparisonPair
            left = workspace.activeTab.linkedPaneIDs.first ??
                panes.first { $0.directory.path == pair?.left.path }?.id ?? workspace.directoryBrowser?.id
            right = workspace.activeTab.linkedPaneIDs.dropFirst().first ??
                panes.first { $0.id != left && $0.directory.path == pair?.right.path }?.id
                ?? panes.first { $0.id != left }?.id
            linked = pair?.linked == true
        }
        .onChange(of: left) { invalidate() }
        .onChange(of: right) { invalidate() }
        .task(id: request) { if request > 0 { await scan() } }
        .task(id: inspected?.id) {
            leftPreview = nil
            rightPreview = nil
            guard let row = inspected else { return }
            let previews = await Task.detached {
                let left = row.left?.kind == .file ? row.left.map { FileEntry.read($0.url) } : nil
                let right = row.right?.kind == .file ? row.right.map { FileEntry.read($0.url) } : nil
                return (left, right)
            }.value
            if !Task.isCancelled { (leftPreview, rightPreview) = previews }
        }
        .alert("单向同步 \(syncPaths.count) 项？", isPresented: $confirmSync) {
            Button("取消", role: .cancel) {}
            Button("同步") { apply(syncPaths, sync: true) }
        } message: {
            Text(includeNewer ? "补齐缺失的文件，并替换目标侧内容不同且修改时间较早的同名文件。"
                 : "将缺失的文件复制到目标侧。")
        }
    }

    private func counterpart(_ title: String, entry: FileEntry?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let entry {
                FilePreview(entry: entry)
            } else {
                ContentUnavailableView(inspected == nil ? "选择一项差异" : "此处没有可预览文件",
                                       systemImage: "doc.viewfinder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func savePair() {
        guard let left = panes.first(where: { $0.id == left }),
              let right = panes.first(where: { $0.id == right }), left !== right else { return }
        workspace.saveComparisonPair(left: left, right: right, linked: linked)
    }

    private func choice(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Array(panes.enumerated()), id: \.element.id) { index, model in
                let number = workspace.activeTab.browsers.firstIndex { $0.id == model.id } ?? index
                Text("面板 \(number + 1) · \(model.directoryName)").tag(Optional(model.id))
            }
        }.disabled(comparing || applying)
    }

    private func invalidate() {
        comparison = nil
        selection.removeAll()
        message = nil
    }

    private func scan() async {
        guard let a = panes.first(where: { $0.id == left }), let b = panes.first(where: { $0.id == right }) else { return }
        comparing = true
        comparison = nil
        selection.removeAll()
        let left = a.directory
        let right = b.directory
        let showHidden = workspace.showHidden
        let worker = Task.detached { try FolderComparison(left: left, right: right, showHidden: showHidden) }
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        comparing = false
        switch result {
        case .success(let value): comparison = value
        case .failure(let error): message = error.localizedDescription
        }
    }

    private func apply(_ selected: Set<String>, sync: Bool) {
        guard let comparison else { return }
        let direction = direction
        applying = true
        Task {
            guard let result = await workspace.applyComparison(comparison, selected: selected, direction: direction, sync: sync)
            else {
                message = "请等待当前文件操作完成。"
                applying = false
                return
            }
            message = "已处理 \(result.revealed.count) 项" + (result.failures.isEmpty ? "" : "\n" + result.failureSummary)
            applying = false
            request += 1
        }
    }
}
