import Foundation

struct FileWorkflow: Codable, Equatable, Identifiable, Sendable {
    enum Transfer: String, Codable, CaseIterable, Identifiable, Sendable {
        case none = "不传输", copy = "复制到", move = "移动到"
        var id: Self { self }
        var operation: PaneTransferOperation? {
            switch self {
            case .none: return nil
            case .copy: return .copy
            case .move: return .move
            }
        }
    }

    var id = UUID()
    var name = ""
    var rename: BatchRenameRule?
    var compresses = false
    var transfer = Transfer.none
    var destination: URL?
    var usesProjectDelivery = false

    var isValid: Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 80 && hasActions && renameIsValid &&
            (transfer == .none || usesProjectDelivery || destination?.isFileURL == true)
    }

    var hasActions: Bool { rename != nil || compresses || transfer != .none }

    private var renameIsValid: Bool {
        guard let rename else { return true }
        switch rename.style {
        case .replace, .prefix: return !rename.text.isEmpty
        case .sequence: return Int(rename.start).map { (0...999_999_999).contains($0) } ?? false
        case .modifiedDate: return true
        }
    }

    var details: String {
        var steps = [String]()
        if let rename { steps.append(rename.style.rawValue) }
        if compresses { steps.append("压缩为 ZIP") }
        if transfer != .none {
            steps.append(transfer.rawValue + " " + (usesProjectDelivery ? "工作区交付目录" : destination?.path ?? "未选择目录"))
        }
        return steps.joined(separator: " → ")
    }
}

struct FileWorkflowRequest: Identifiable {
    let id = UUID()
    let draft: FileWorkflow
    var entries: [FileEntry] = []
    var browser: BrowserModel?
}

struct FileWorkflowPlan: Sendable {
    let sources: [URL]
    let rename: BatchRenamePlan?
    let archiveDirectory: URL?
    let destination: URL?
    let preparedDestination: TransferFiles.Destination?
    let stamps: [URL: FileStamp]

    init(_ workflow: FileWorkflow, files: [URL], projectDelivery: URL?) throws {
        guard workflow.isValid else { throw FileWorkflowError.invalid }
        sources = FileSystem.selectedRoots(files)
        guard let first = sources.first else { throw FileWorkflowError.missingSelection }
        let stamps = try Dictionary(uniqueKeysWithValues: sources.map { url in
            guard let stamp = FileStamp(url) else { throw FileWorkflowError.missingFile(url) }
            return (url, stamp)
        })
        self.stamps = stamps
        if workflow.transfer != .none {
            guard let target = workflow.usesProjectDelivery ? projectDelivery : workflow.destination else {
                throw FileWorkflowError.missingDelivery
            }
            let folder = try TransferFiles.Destination(target)
            destination = folder.url
            preparedDestination = folder
            if !workflow.compresses || workflow.rename != nil {
                guard !sources.contains(where: { url in
                    let source = url.resolvingSymlinksInPath()
                    return folder.physical.path == source.path ||
                        (stamps[url]?.directory == true && folder.physical.path.hasPrefix(source.path + "/"))
                }) else { throw FileWorkflowError.insideSelection }
            }
        } else {
            destination = nil
            preparedDestination = nil
        }
        if workflow.compresses {
            let parent = first.deletingLastPathComponent()
            guard sources.allSatisfy({ $0.deletingLastPathComponent().path == parent.path }) else {
                throw FileWorkflowError.archiveParents
            }
            _ = try TransferFiles.Destination(parent)
            archiveDirectory = parent
        } else {
            archiveDirectory = nil
        }
        if let rule = workflow.rename {
            let plan = try BatchRenamePlan(items: sources.map { FileEntry.read($0) }, rule: rule)
            if let issue = plan.rows.first(where: { $0.issue != nil }) {
                throw FileWorkflowError.renameConflict(issue.source.lastPathComponent, issue.issue ?? "")
            }
            rename = plan
        } else {
            rename = nil
        }
    }

    func run() -> Run {
        var result = Run(outputs: sources)
        do {
            try preparedDestination?.validate()
            for url in sources {
                guard FileStamp(url) == stamps[url] else { throw FileWorkflowError.missingFile(url) }
            }
            if let rename, rename.canApply {
                result.renamed = try rename.apply()
                let destinations = Dictionary(uniqueKeysWithValues: result.renamed.relocations.map { ($0.original, $0.current) })
                result.outputs = sources.map { destinations[$0] ?? $0 }
            }
            if let archiveDirectory {
                let archive = try FileArchive.compress(result.outputs, in: archiveDirectory)
                result.outputs = [archive]
                result.archive = archive
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    struct Run: Sendable {
        var outputs: [URL]
        var renamed = FileOperationResult()
        var archive: URL?
        var error: String?
    }
}

enum FileWorkflowError: LocalizedError {
    case invalid, missingSelection, missingDelivery, insideSelection, archiveParents
    case missingFile(URL), renameConflict(String, String)

    var errorDescription: String? {
        switch self {
        case .invalid: return "请检查流程的步骤和目标。"
        case .missingSelection: return "请选择要处理的文件或文件夹。"
        case .missingDelivery: return "请先为当前工作区设置交付目录。"
        case .insideSelection: return "目标目录位于所选文件夹中。"
        case .archiveParents: return "压缩步骤需要所选项目位于同一文件夹。"
        case .missingFile(let url): return "「\(url.lastPathComponent)」已变化或无法读取，请重新选择。"
        case .renameConflict(let name, let issue): return "「\(name)」无法重命名。\(issue)"
        }
    }
}
