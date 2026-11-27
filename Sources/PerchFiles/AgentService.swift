import AppKit
import Observation

struct AgentGrant: Codable, Equatable, Sendable {
    struct Folder: Codable, Equatable, Sendable {
        let url: URL
        let stamp: FileStamp

        init(_ selected: URL) throws {
            let folder = try TransferFiles.Destination(selected)
            url = folder.physical
            stamp = folder.stamp
        }

        func validate() throws {
            guard FileSystem.physicalDirectory(url).path == url.path, stamp.sameObject(as: FileStamp(url)) else {
                throw TransferFileError.changedFolder
            }
        }

        func contains(_ file: URL) -> Bool {
            let parent = FileSystem.physicalDirectory(file.deletingLastPathComponent()).path
            return parent == url.path || parent.hasPrefix(prefix)
        }

        var prefix: String { url.path == "/" ? "/" : url.path + "/" }
    }

    let token: String
    let workspaceID: UUID
    let root: Folder
    let delivery: Folder?

    enum CodingKeys: String, CodingKey { case token, workspaceID, root, delivery }

    init(workspaceID: UUID, root: Folder, delivery: Folder?, token: String = UUID().uuidString + UUID().uuidString) {
        self.workspaceID = workspaceID
        self.root = root
        self.delivery = delivery
        self.token = token
    }
}

@MainActor @Observable
final class AgentJob: Identifiable {
    enum Status: String {
        case preparing, awaiting_approval, running, transferring, completed, failed, cancelled
        var title: String {
            switch self {
            case .preparing: return "正在检查"
            case .awaiting_approval: return "待确认"
            case .running: return "正在运行"
            case .transferring: return "传输中"
            case .completed: return "已完成"
            case .failed: return "未完成"
            case .cancelled: return "已取消"
            }
        }
        var terminal: Bool { self == .completed || self == .failed || self == .cancelled }
    }

    struct Input: Identifiable, Sendable {
        let id: UUID
        let url: URL
        let stamp: FileStamp
    }

    let id = UUID()
    let requestID: UUID
    let workflow: FileWorkflow
    let inputs: [Input]
    var selected: Set<UUID>
    var status = Status.preparing
    var revision = UUID()
    var plan: FileWorkflowPlan?
    var transferID: UUID?
    var outputs: [AgentReply.Item] = []
    var outputURLs: [URL] = []
    var warnings: [String] = []
    var predictedConflicts: [String] = []
    var issue: String?

    init(requestID: UUID, workflow: FileWorkflow, inputs: [Input]) {
        self.requestID = requestID
        self.workflow = workflow
        self.inputs = inputs
        selected = Set(inputs.map(\.id))
    }
}

@MainActor @Observable
final class AgentService {
    static let shared = AgentService()

    private struct SearchBatch {
        let folder: SmartFolder
        let references: [AgentJob.Input]
    }

    private let defaults: UserDefaults
    private let grantKey = "wfolder.agent.grant.v1"
    private(set) var grant: AgentGrant?
    private(set) var jobs: [AgentJob] = []
    var focusedJob: UUID?
    private(set) var connectionIssue: String?
    private(set) var listening = false
    private(set) var hasReceivedRequest = false
    private var searches: [SearchBatch] = []
    private var searching = false
    @ObservationIgnored private var listener: AgentListener?
    @ObservationIgnored private(set) weak var workspace: BrowserWorkspace?
    @ObservationIgnored var bringForward: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grant = defaults.data(forKey: grantKey).flatMap { try? JSONDecoder().decode(AgentGrant.self, from: $0) }
    }

    var pendingCount: Int { jobs.filter { $0.status == .awaiting_approval }.count }
    var savedWorkspaces: [NamedWorkspace] { workspace?.namedWorkspaces ?? WorkspaceStorage(defaults: defaults).named }

    func attach(_ workspace: BrowserWorkspace) {
        self.workspace = workspace
        startIfNeeded()
    }

    func pair(workspaceID: UUID? = nil, root: URL, delivery: URL?) throws {
        let root = try AgentGrant.Folder(root)
        let delivery = try delivery.map(AgentGrant.Folder.init)
        let id: UUID
        if let workspaceID {
            guard savedWorkspaces.contains(where: { $0.id == workspaceID }) else { throw AgentError.workspaceUnavailable }
            id = workspaceID
        } else {
            let saved = WorkspaceStorage(defaults: defaults).saveFolderWorkspace(root.url)
            workspace?.reloadNamedWorkspaces()
            id = saved.id
        }
        let new = AgentGrant(workspaceID: id, root: root, delivery: delivery)
        revoke()
        grant = new
        defaults.set(try JSONEncoder().encode(new), forKey: grantKey)
        startIfNeeded()
    }

    func revoke() {
        let pending = jobs.filter { $0.status == .preparing || $0.status == .awaiting_approval }
        pending.forEach(cancel)
        jobs.removeAll { $0.status.terminal }
        let remaining = Set(jobs.map(\.id))
        grants = grants.filter { remaining.contains($0.key) }
        searches.removeAll()
        grant = nil
        hasReceivedRequest = false
        defaults.removeObject(forKey: grantKey)
        connectionIssue = nil
    }

    enum Configuration: String, CaseIterable, Identifiable {
        case codex = "Codex"
        case json = "其他 MCP 客户端"
        var id: Self { self }

        func render(executable: URL, token: String) -> String? {
            switch self {
            case .codex:
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                guard let command = try? encoder.encode(executable.path),
                      let credential = try? encoder.encode(token) else { return nil }
                return """
                [mcp_servers.wfolder]
                command = \(String(decoding: command, as: UTF8.self))
                args = ["--mcp"]

                [mcp_servers.wfolder.env]
                WFOLDER_AGENT_TOKEN = \(String(decoding: credential, as: UTF8.self))

                """
            case .json:
                guard let data = try? JSONSerialization.data(withJSONObject: [
                    "mcpServers": ["wfolder": ["command": executable.path, "args": ["--mcp"],
                                               "env": ["WFOLDER_AGENT_TOKEN": token]]]
                ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    func configuration(_ format: Configuration) -> String? {
        guard let grant, listening, let executable = Bundle.main.executableURL else { return nil }
        return format.render(executable: executable, token: grant.token)
    }

    @discardableResult
    func copyConfiguration(_ format: Configuration) -> Bool {
        guard let text = configuration(format) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func retryConnection() { startIfNeeded() }

    private func startIfNeeded() {
        guard grant != nil, listener == nil else { return }
        do {
            listener = try AgentListener { [weak self] call in
                guard let self else { return .failure("wfolder is not available.") }
                return await self.receive(call)
            }
            listening = true
            connectionIssue = nil
        } catch {
            listening = false
            connectionIssue = "本机连接启动失败。请关闭其他 wfolder 实例后重试。"
        }
    }

    func receive(_ call: AgentCall) async -> AgentReply {
        guard let grant, call.token == grant.token, let workspace,
              let saved = workspace.namedWorkspaces.first(where: { $0.id == grant.workspaceID }) else {
            return .failure("This client is not paired with an available wfolder workspace.")
        }
        if !hasReceivedRequest { hasReceivedRequest = true }
        do {
            switch call.tool {
            case "workspace":
                return AgentReply(workspace: .init(id: saved.id, name: saved.name))
            case "open_workspace":
                try grant.root.validate()
                openWorkspace(saved, in: workspace)
                return AgentReply(workspace: .init(id: saved.id, name: saved.name), status: "presented")
            case "search":
                return try await search(call, grant: grant, saved: saved, memory: workspace.aiMemory)
            case "show_search":
                guard let batch = searches.first(where: { $0.folder.id == call.search_id }) else { throw AgentError.missingReference }
                try grant.root.validate()
                openWorkspace(saved, in: workspace)
                workspace.showSmartFolderResults(batch.folder)
                return AgentReply(search_id: batch.folder.id, status: "presented")
            case "show_file":
                try grant.root.validate()
                guard let id = call.file_id, let url = fileURL(id, grant: grant),
                      FileStamp(url)?.regular == true,
                      grant.root.contains(url) || grant.delivery?.contains(url) == true else {
                    throw AgentError.missingReference
                }
                openWorkspace(saved, in: workspace)
                workspace.revealInFolder(url)
                workspace.activeBrowser.showPreview = true
                return AgentReply(status: "presented")
            case "list_workflows":
                let workflows = workspace.aiMemory.workflows.filter { Self.allowed($0, by: grant) }
                return AgentReply(workflows: workflows.map { .init(id: $0.id, name: $0.name) })
            case "prepare_workflow":
                return try prepare(call, grant: grant, workspace: workspace)
            case "show_job", "job_status":
                guard let job = jobs.first(where: { $0.id == call.job_id }), grants[job.id] == grant.token else {
                    throw AgentError.missingReference
                }
                if call.tool == "show_job" { present(job) }
                return status(job, workspace: workspace)
            default:
                return .failure("Unknown wfolder tool.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    @ObservationIgnored private var grants: [UUID: String] = [:]

    private func fileURL(_ id: UUID, grant: AgentGrant) -> URL? {
        for batch in searches {
            if let input = batch.references.first(where: { $0.id == id }), input.stamp == FileStamp(input.url) {
                return input.url
            }
        }
        for job in jobs where grants[job.id] == grant.token {
            if let item = job.outputs.first(where: { $0.id == id }) { return item.url }
        }
        return nil
    }

    private func openWorkspace(_ saved: NamedWorkspace, in workspace: BrowserWorkspace) {
        if let tab = workspace.tabs.first(where: { $0.namedWorkspaceID == saved.id }) { workspace.selectTab(tab.id) }
        else { workspace.openWorkspace(saved) }
        workspace.showFolderBrowser()
        bringForward?()
    }

    private func search(_ call: AgentCall, grant: AgentGrant, saved: NamedWorkspace, memory: AIMemory) async throws -> AgentReply {
        let query = call.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = call.limit ?? 25
        let days = call.days ?? 0
        let types = call.extensions ?? []
        guard (1...50).contains(limit), (0...3650).contains(days), query.count <= 180, types.count <= 12,
              types.allSatisfy({ $0.range(of: #"^\.?[A-Za-z0-9][A-Za-z0-9_+-]{0,19}$"#, options: .regularExpression) != nil }),
              !query.isEmpty || days > 0 || !types.isEmpty else { throw AgentError.invalidSearch }
        guard !searching else { throw AgentError.searchBusy }
        searching = true
        defer { searching = false }
        let context = SearchMemoryContext(query: query, root: grant.root.url, workspaceID: saved.id,
                                          workspaceName: saved.name, source: .assistant)
        let suffixes = Set(types.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() })
        let since = days == 0 ? nil : Calendar.current.date(byAdding: .day, value: -days, to: .now)
        let semantics = SearchSemantics(concepts: [[query]])
        let (result, inputs) = try await Task.detached(priority: .userInitiated) {
            try grant.root.validate()
            let matches = query.isEmpty ? nil : semantics.matcher(in: grant.root.url, readsContents: true, indexed: [])
            let result = try FileSystem.search(grant.root.url, query: "", showHidden: false,
                includesCandidate: { url in
                    if !suffixes.isEmpty && !suffixes.contains(url.pathExtension.lowercased()) { return false }
                    guard let stamp = FileStamp(url), stamp.regular, grant.root.contains(url) else { return false }
                    return since.map { stamp.modified >= $0 } ?? true
                }, includesEntry: { entry in
                    if FileListing.matches(name: entry.name, filename: entry.filename, query: query) { return true }
                    return matches?(entry) ?? query.isEmpty
                })
            let stamps = Dictionary(uniqueKeysWithValues: result.entries.compactMap { entry in
                FileStamp(entry.url).flatMap { $0.regular ? (entry.url, $0) : nil }
            })
            return (result, stamps)
        }.value
        guard self.grant == grant else { throw AgentError.revoked }
        let sorted = result.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ordered = memory.rank(sorted, in: context) ?? sorted
        let refs = ordered.prefix(limit).compactMap { entry in
            inputs[entry.url].map { AgentJob.Input(id: UUID(), url: entry.url, stamp: $0) }
        }
        let paths = Set(refs.map { $0.url.standardizedFileURL.path })
        let folder = SmartFolder(name: query.isEmpty ? "Agent 搜索" : query, root: grant.root.url,
                                 feedbackContext: context, limitedTo: paths)
        searches.insert(SearchBatch(folder: folder, references: refs), at: 0)
        if searches.count > 12 { searches.removeLast() }
        let items = refs.map { ref in
            AgentReply.Item(id: ref.id, name: ref.url.lastPathComponent,
                            path: relative(ref.url, in: grant.root), modified: ref.stamp.modified)
        }
        return AgentReply(files: items, search_id: folder.id, match_count: result.entries.count, unreadable_directories: result.unreadable)
    }

    private static func allowed(_ workflow: FileWorkflow, by grant: AgentGrant) -> Bool {
        guard workflow.isValid else { return false }
        guard workflow.transfer != .none else { return true }
        if workflow.usesProjectDelivery { return grant.delivery != nil }
        guard let destination = workflow.destination else { return false }
        let path = destination.standardizedFileURL.path
        return path == grant.root.url.path || path.hasPrefix(grant.root.prefix) || path == grant.delivery?.url.path
    }

    private func prepare(_ call: AgentCall, grant: AgentGrant, workspace: BrowserWorkspace) throws -> AgentReply {
        guard let key = call.request_id, let id = call.workflow_id, let fileIDs = call.file_ids,
              (1...50).contains(fileIDs.count), Set(fileIDs).count == fileIDs.count else { throw AgentError.invalidPlan }
        if let previous = jobs.first(where: { $0.requestID == key && grants[$0.id] == grant.token }) {
            guard previous.workflow.id == id, previous.inputs.map(\.id) == fileIDs else { throw AgentError.requestConflict }
            return status(previous, workspace: workspace)
        }
        guard jobs.count < 100 else { throw AgentError.tooManyJobs }
        guard let workflow = workspace.aiMemory.workflows.first(where: { $0.id == id }),
              Self.allowed(workflow, by: grant) else { throw AgentError.invalidPlan }
        let all = Dictionary(uniqueKeysWithValues: searches.flatMap(\.references).map { ($0.id, $0) })
        let inputs = fileIDs.compactMap { all[$0] }
        guard inputs.count == fileIDs.count else { throw AgentError.missingReference }
        let job = AgentJob(requestID: key, workflow: workflow, inputs: inputs)
        grants[job.id] = grant.token
        jobs.insert(job, at: 0)
        updatePreview(job, grant: grant)
        return status(job, workspace: workspace)
    }

    func toggle(_ input: AgentJob.Input, in job: AgentJob, enabled: Bool) {
        guard let grant, grants[job.id] == grant.token,
              job.status == .preparing || job.status == .awaiting_approval else { return }
        if enabled { job.selected.insert(input.id) } else { job.selected.remove(input.id) }
        updatePreview(job, grant: grant)
    }

    private func updatePreview(_ job: AgentJob, grant: AgentGrant) {
        let revision = UUID()
        job.revision = revision
        job.plan = nil
        job.issue = nil
        job.predictedConflicts = []
        job.status = .preparing
        let selected = job.inputs.filter { job.selected.contains($0.id) }
        let workflow = job.workflow
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let plan = try Self.checkedPlan(workflow, inputs: selected, grant: grant)
                    return (plan, Self.predictedConflicts(plan, workflow: workflow))
                }
            }.value
            guard self.grant == grant, job.revision == revision, job.status == .preparing else { return }
            switch result {
            case .success(let (plan, conflicts)):
                job.plan = plan
                job.predictedConflicts = conflicts
            case .failure(let error): job.issue = error.localizedDescription
            }
            job.status = .awaiting_approval
        }
    }

    nonisolated private static func checkedPlan(_ workflow: FileWorkflow, inputs: [AgentJob.Input],
                                               grant: AgentGrant) throws -> FileWorkflowPlan {
        try grant.root.validate()
        for input in inputs {
            guard grant.root.contains(input.url), input.stamp == FileStamp(input.url), input.stamp.regular else {
                throw FileWorkflowError.missingFile(input.url)
            }
        }
        let plan = try FileWorkflowPlan(workflow, files: inputs.map(\.url), projectDelivery: grant.delivery?.url)
        if let target = plan.preparedDestination {
            let path = target.physical.path
            if path == grant.delivery?.url.path { try grant.delivery?.validate() }
            else if path != grant.root.url.path && !path.hasPrefix(grant.root.prefix) { throw AgentError.outsideScope }
        }
        return plan
    }

    nonisolated private static func predictedConflicts(_ plan: FileWorkflowPlan, workflow: FileWorkflow) -> [String] {
        guard let destination = plan.preparedDestination else { return [] }
        let renamed = Dictionary(uniqueKeysWithValues: (plan.rename?.rows ?? []).map { ($0.source, $0.proposed) })
        let names: [String]
        if workflow.compresses {
            names = [(plan.sources.count == 1 ? renamed[plan.sources[0]] ?? plan.sources[0].lastPathComponent : "归档") + ".zip"]
        } else {
            names = plan.sources.compactMap { source in
                if workflow.transfer == .move, FileSystem.physicalDirectory(source.deletingLastPathComponent()).path ==
                    destination.physical.path { return nil }
                return renamed[source] ?? source.lastPathComponent
            }
        }
        return names.filter { FileStamp(destination.physical.appendingPathComponent($0)) != nil }
    }

    func approve(_ job: AgentJob) {
        guard let workspace, let grant, grants[job.id] == grant.token,
              job.status == .awaiting_approval, let preview = job.plan else { return }
        guard !workspace.hasFileMutations else {
            job.issue = "有其他文件操作正在进行，请稍后确认。"
            return
        }
        let workflow = job.workflow
        let inputs = job.inputs.filter { job.selected.contains($0.id) }
        job.status = .running
        job.issue = nil
        Task {
            await workspace.executeWorkflow(workflow, prepare: {
                let current = try Self.checkedPlan(workflow, inputs: inputs, grant: grant)
                let previous = preview.rename?.rows.map(\.proposed)
                guard current.rename?.rows.map(\.proposed) == previous,
                      current.preparedDestination?.physical == preview.preparedDestination?.physical,
                      current.preparedDestination?.stamp.sameObject(as: preview.preparedDestination?.stamp) != false else {
                    throw AgentError.planChanged
                }
                return current
            }, onTransfer: { id in
                job.transferID = id
                job.status = .transferring
            }) { result in
                job.outputURLs = result.outputs
                job.outputs = result.outputs.map { url in
                    let relativePath = self.relative(url, in: grant.root) ?? grant.delivery.flatMap { self.relative(url, in: $0) }
                    return .init(id: UUID(), name: url.lastPathComponent, path: relativePath, url: relativePath == nil ? nil : url)
                }
                job.warnings = result.warnings
                job.issue = result.error
                job.status = result.cancelled ? .cancelled : result.error != nil ? .failed : .completed
            }
        }
    }

    func cancel(_ job: AgentJob) {
        guard job.status == .awaiting_approval || job.status == .preparing else { return }
        job.status = .cancelled
        job.plan = nil
        job.issue = nil
    }

    func present(_ job: AgentJob? = nil) {
        guard let workspace else { return }
        if let job { focusedJob = job.id }
        bringForward?()
        if workspace.presentedTool == nil { workspace.presentedTool = .agent }
    }

    private func status(_ job: AgentJob, workspace: BrowserWorkspace) -> AgentReply {
        let transfer = workspace.transfers.jobs.first { $0.id == job.transferID }
        let state = transfer?.state == .conflicts ? "awaiting_conflict_resolution" : job.status.rawValue
        let errors = job.issue.map { [$0] } ?? []
        return AgentReply(job_id: job.id, status: state, outputs: job.outputs, selected_count: job.selected.count,
                          processed_count: transfer?.processed, total_count: transfer?.total, warnings: job.warnings + errors + (job.predictedConflicts.isEmpty || job.status.terminal ? [] :
                             ["目标目录已有同名项目：" + job.predictedConflicts.joined(separator: "、")]))
    }

    private func relative(_ url: URL, in folder: AgentGrant.Folder) -> String? {
        let value = url.standardizedFileURL.path
        return value.hasPrefix(folder.prefix) ? String(value.dropFirst(folder.prefix.count)) : nil
    }
}

private enum AgentError: LocalizedError {
    case invalidSearch, searchBusy, missingReference, revoked, invalidPlan, requestConflict, tooManyJobs, outsideScope, planChanged
    case workspaceUnavailable

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable: return "所选工作区不可用，请重新选择。"
        case .invalidSearch: return "请提供有效的搜索词、日期或扩展名。"
        case .searchBusy: return "另一次 Agent 搜索正在进行，请稍后重试。"
        case .missingReference: return "引用不存在或已过期，请重新搜索。"
        case .revoked: return "此 Agent 连接已撤销。"
        case .invalidPlan: return "请选择授权范围内的已保存流程和搜索结果。"
        case .requestConflict: return "此请求 ID 已用于另一批文件或流程。"
        case .tooManyJobs: return "已达到本次会话的任务上限。"
        case .outsideScope: return "目标目录在 Agent 授权范围之外。"
        case .planChanged: return "来源或目标已变化，请创建新的任务以便重新确认。"
        }
    }
}
