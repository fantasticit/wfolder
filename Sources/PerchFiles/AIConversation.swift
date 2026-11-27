import Foundation
import Observation

@MainActor @Observable
final class AIConversation {
    struct Turn: Identifiable {
        let id: UUID
        let prompt: String
        var preface: String?
        var reply: Reply

        init(id: UUID = UUID(), prompt: String, preface: String? = nil, reply: Reply = .pending) {
            self.id = id
            self.prompt = prompt
            self.preface = preface
            self.reply = reply
        }
    }

    enum Reply {
        case pending, searching, organizing, stopping, stopped, interrupted
        case answer(String), failed(String)
        case searchResult(AISearchSummary)
        case organizationResult(title: String, details: [String])
        case proposal(AIProposal, AIFolderContext)
        case previousProposal(title: String, details: [String])
        case archived(title: String, details: [String], status: String)
    }

    var draft = ""
    private(set) var turns: [Turn] = []
    private(set) var scrollRevision = 0
    private(set) var partialText = ""
    private(set) var activeID = UUID()
    private(set) var records: [AIChatRecord] = []
    private(set) var historyIssue: String?
    private let archive: AIChatHistory
    private var request: Task<Void, Never>?
    private var route: AIChatRoute?
    private var history: [AIExchange] = []

    init(archive: AIChatHistory = AIChatHistory()) {
        self.archive = archive
        let restored = archive.restore()
        records = restored.records
        activeID = archive.selectedID ?? records.first?.id ?? UUID()
        if let record = records.first(where: { $0.id == activeID }) { load(record) }
        if restored.failed { historyIssue = "部分对话无法读取。" }
    }

    var isReplying: Bool { request != nil }
    var isSearching: Bool {
        if case .searching = turns.last?.reply { return true }
        return false
    }
    var isOrganizing: Bool {
        switch turns.last?.reply {
        case .organizing, .stopping: return true
        default: return false
        }
    }
    var isStopping: Bool {
        if case .stopping = turns.last?.reply { return true }
        return false
    }

    var isOverLimit: Bool { draft.utf8.count > 16_000 || draft.count > 4_000 }
    var canSend: Bool { !isReplying && !isOverLimit && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func send(in workspace: BrowserWorkspace) {
        guard canSend else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = AIFolderContext(workspace)
        let turn = Turn(prompt: prompt)
        archiveProposal(status: "已被后续消息替代")
        turns.append(turn)
        draft = ""
        scrollRevision += 1
        saveCurrent()

        request = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            do {
                if let intent = AIIntent.directSearch(for: prompt) {
                    history.append(AIExchange(user: prompt, assistant: #"{"action":"search","location":{"place":"computer"},"filters":{"kind":"image"}}"#))
                    history = Array(history.suffix(8))
                    try await search(intent, in: workspace, context: context, turn: turn)
                    return
                }
                let settings = AISettingsStore.shared
                let provider = settings.provider
                let connection = try settings.connection(provider: provider, profile: settings.profile(for: provider))
                let route = AIChatRoute(connection)
                if self.route != route {
                    self.route = route
                    history.removeAll()
                }
                let result = try await AIClient.shared.streamReply(to: prompt, history: history, using: connection) { [weak self] text in
                    await self?.streamText(text, for: turn.id)
                }
                try Task.checkCancellation()
                history.append(result.exchange)
                if history.count > 8 { history.removeFirst() }

                guard let intent = result.intent else {
                    finish(turn.id, with: .answer(result.text))
                    return
                }
                if intent.action == .answer {
                    let text = AIClient.visibleReply(intent.message ?? "")
                    guard !text.isEmpty else { throw AIServiceError.response }
                    finish(turn.id, with: .answer(text))
                    return
                }
                if intent.action == .searchResults {
                    if let previous = latestSearch(before: turn.id) {
                        finishSearch(turn.id, summary: previous)
                    } else {
                        finish(turn.id, with: .answer("这段对话还没有完成的搜索。"))
                    }
                    return
                }
                if intent.action == .search {
                    try await search(intent, in: workspace, context: context, turn: turn)
                    return
                }
                guard context.matches(workspace) else { throw AIActionError.contextChanged }
                let proposal = try await intent.proposal(in: workspace, context: context)
                try Task.checkCancellation()
                guard context.matches(workspace) else { throw AIActionError.contextChanged }
                if !result.text.isEmpty { turns[turns.count - 1].preface = result.text }
                partialText = ""
                if var rule = proposal.organizationRule {
                    rule.source = FileSystem.physicalDirectory(rule.source)
                    rule.destination = FileSystem.physicalDirectory(rule.destination)
                    let scope = AIAutomationPermissions.shared.scope
                    if scope.permits(rule.source), scope.permits(rule.destination) {
                        try await organize(rule, scope: scope, turn: turn.id, workspace: workspace, context: context)
                        return
                    }
                }
                finish(turn.id, with: proposal.apply == nil ? .answer(proposal.title) : .proposal(proposal, context))
            } catch {
                if turns.last?.id == turn.id, !partialText.isEmpty { turns[turns.count - 1].preface = partialText }
                if Task.isCancelled || error is CancellationError {
                    finish(turn.id, with: .stopped)
                } else {
                    finish(turn.id, with: .failed(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        guard let request, let last = turns.last else { return }
        request.cancel()
        if isOrganizing { turns[turns.count - 1].reply = .stopping }
        else {
            if !partialText.isEmpty { turns[turns.count - 1].preface = partialText }
            finish(last.id, with: .stopped)
        }
    }

    func reset() {
        guard !isReplying else { return }
        activeID = UUID()
        archive.select(activeID)
        turns.removeAll()
        history.removeAll()
        route = nil
        draft = ""
        scrollRevision += 1
    }

    func select(_ id: UUID) {
        guard !isReplying, id != activeID, let record = records.first(where: { $0.id == id }) else { return }
        load(record)
        archive.select(id)
        scrollRevision += 1
    }

    func delete(_ id: UUID) {
        guard !isReplying else { return }
        do {
            try archive.delete(id)
            records.removeAll { $0.id == id }
            if activeID == id {
                if let next = records.first { select(next.id) } else { reset() }
            }
            historyIssue = nil
        } catch {
            historyIssue = "无法删除对话。\(error.localizedDescription)"
        }
    }

    private func streamText(_ text: String, for id: UUID) {
        guard request != nil, turns.last?.id == id else { return }
        partialText = text
    }

    private func load(_ record: AIChatRecord) {
        activeID = record.id
        route = record.route
        history = Array(record.exchanges.suffix(8))
        draft = ""
        partialText = ""
        turns = record.turns.map { turn in
            let reply: Reply
            switch turn.reply {
            case .interrupted: reply = .interrupted
            case .stopped: reply = .stopped
            case .answer(let text):
                let visible = AIClient.visibleReply(text)
                reply = visible.isEmpty ? .failed("这条回复没有保存可显示的结果。可以重新发送搜索。") : .answer(visible)
            case .failed(let text): reply = .failed(text)
            case .searchResult(let summary): reply = .searchResult(summary)
            case .organizationResult(let title, let details): reply = .organizationResult(title: title, details: details)
            case .proposal(let title, let details): reply = .previousProposal(title: title, details: details)
            case .archived(let title, let details, let status): reply = .archived(title: title, details: details, status: status)
            }
            let preface = turn.preface.map(AIClient.visibleReply).flatMap { $0.isEmpty ? nil : $0 }
            return Turn(id: turn.id, prompt: turn.prompt, preface: preface, reply: reply)
        }
    }

    private func saveCurrent() {
        guard !turns.isEmpty else { return }
        let snapshot = turns.map { turn in
            let reply: AIChatRecord.Turn.Reply
            switch turn.reply {
            case .pending, .searching, .organizing, .stopping, .interrupted: reply = .interrupted
            case .stopped: reply = .stopped
            case .answer(let text): reply = .answer(text)
            case .failed(let text): reply = .failed(text)
            case .searchResult(let summary): reply = .searchResult(summary)
            case .organizationResult(let title, let details): reply = .organizationResult(title: title, details: details)
            case .proposal(let proposal, _): reply = .proposal(title: proposal.title, details: proposal.details)
            case .previousProposal(let title, let details): reply = .proposal(title: title, details: details)
            case .archived(let title, let details, let status): reply = .archived(title: title, details: details, status: status)
            }
            return AIChatRecord.Turn(id: turn.id, prompt: turn.prompt, preface: turn.preface, reply: reply)
        }
        let record = AIChatRecord(id: activeID, updated: .now, turns: snapshot, route: route, exchanges: history)
        records.removeAll { $0.id == activeID }
        records.insert(record, at: 0)
        do {
            try archive.save(record)
            archive.select(record.id)
            historyIssue = nil
        } catch {
            historyIssue = "无法保存对话。\(error.localizedDescription)"
        }
    }

    private func search(_ intent: AIIntent, in workspace: BrowserWorkspace, context: AIFolderContext,
                        turn: Turn) async throws {
        turns[turns.count - 1].reply = .searching
        partialText = ""
        scrollRevision += 1
        let folder = try await intent.searchFolder(in: workspace, context: context, prompt: turn.prompt)
        try Task.checkCancellation()
        let summary = try await searchSummary(folder, in: workspace)
        finishSearch(turn.id, summary: summary)
    }

    func rerunSearch(_ original: SmartFolder, at directory: URL, in workspace: BrowserWorkspace) {
        guard request == nil else { return }
        var folder = original
        folder.id = UUID()
        folder.root = directory
        folder.feedbackContext?.root = directory
        let turn = Turn(prompt: "在所选目录重新搜索「\(folder.name)」", reply: .searching)
        archiveProposal(status: "已被后续消息替代")
        turns.append(turn)
        scrollRevision += 1
        saveCurrent()
        request = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            do {
                try Task.checkCancellation()
                let summary = try await searchSummary(folder, in: workspace)
                history.append(AIExchange(user: turn.prompt, assistant: "Searched in the directory selected locally."))
                history = Array(history.suffix(8))
                finishSearch(turn.id, summary: summary)
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                finish(turn.id, with: cancelled ? .stopped : .failed(error.localizedDescription))
            }
        }
    }

    private func searchSummary(_ folder: SmartFolder, in workspace: BrowserWorkspace) async throws -> AISearchSummary {
        let pane = workspace.openSmartFolder(folder)
        pane.start()
        let results = try await withTaskCancellationHandler {
            try await pane.completedSmartSearch()
        } onCancel: {
            Task { @MainActor in pane.stopSmartSearch() }
        }
        try Task.checkCancellation()
        return AISearchSummary(folder: folder, results: results)
    }

    private func latestSearch(before turn: UUID) -> AISearchSummary? {
        for earlier in turns.reversed() where earlier.id != turn {
            if case .searchResult(let summary) = earlier.reply { return summary }
        }
        return nil
    }

    private func finishSearch(_ turn: UUID, summary: AISearchSummary) {
        guard turns.last?.id == turn else { return }
        if let index = history.indices.last { history[index].searchOutcome = summary.providerContext }
        finish(turn, with: .searchResult(summary))
    }

    private func organize(_ rule: OrganizationRule, scope: AIAutomationScope, turn: UUID,
                          workspace: BrowserWorkspace, context: AIFolderContext) async throws {
        turns[turns.count - 1].reply = .organizing
        scrollRevision += 1
        let plan = try await OrganizationPlan.prepare(rule, showHidden: false)
        try Task.checkCancellation()
        guard context.matches(workspace) else { throw AIActionError.contextChanged }

        var result = FileOperationResult()
        if plan.actionableCount > 0 {
            guard let applied = await workspace.applyOrganization(plan, scope: scope) else {
                finish(turn, with: .failed("有其他文件操作正在进行，整理尚未开始。"))
                return
            }
            result = applied
        }
        let moved = result.relocations.count
        let skipped = plan.rows.count - plan.actionableCount
        var details = [rule.destination.path, "已移动 \(moved) 项 · 跳过 \(skipped) 项"]
        if skipped > 0 {
            let reasons = Dictionary(grouping: plan.rows.compactMap(\.issue), by: { $0 })
            details.append(contentsOf: reasons.sorted(by: { $0.key < $1.key }).map { "\($0.value.count) 项 · \($0.key)" })
        }
        if plan.unreadable > 0 { details.append("\(plan.unreadable) 个子目录无法读取") }
        if !result.failures.isEmpty { details.append(result.failureSummary) }
        if moved > 0 { details.append("可从操作历史撤销本次移动。") }
        let title = Task.isCancelled ? "已停止整理" : (result.failures.isEmpty ? "整理完成" : "整理结束，部分项目未能处理")
        finish(turn, with: .organizationResult(title: title, details: details))
    }

    func confirm(_ id: UUID, in workspace: BrowserWorkspace) -> (() -> Void)? {
        guard let last = turns.last, last.id == id,
              case .proposal(let proposal, let context) = last.reply,
              let apply = proposal.apply else { return nil }
        guard context.matches(workspace) else {
            finish(id, with: .failed(AIActionError.contextChanged.localizedDescription))
            return nil
        }
        archiveProposal(status: "已确认")
        saveCurrent()
        return { [weak self, weak workspace] in
            guard let workspace else { return }
            guard context.matches(workspace) else {
                let message = AIActionError.contextChanged.localizedDescription
                self?.finish(id, with: .failed(message))
                workspace.activeBrowser.issue = BrowserIssue(title: "无法执行建议", message: message)
                return
            }
            apply()
        }
    }

    private func archiveProposal(status: String) {
        guard let last = turns.last, case .proposal(let proposal, _) = last.reply else { return }
        turns[turns.count - 1].reply = .archived(title: proposal.title, details: proposal.details, status: status)
    }

    private func finish(_ id: UUID, with reply: Reply) {
        guard turns.last?.id == id else { return }
        turns[turns.count - 1].reply = reply
        partialText = ""
        request = nil
        scrollRevision += 1
        saveCurrent()
    }
}
