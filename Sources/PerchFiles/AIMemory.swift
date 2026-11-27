import Foundation
import Observation

struct SearchMemoryContext: Codable, Equatable, Sendable {
    var query: String
    var root: URL
    var workspaceID: UUID?
    var workspaceName: String?
    var source: Source

    enum Source: String, Codable, Sendable { case files, assistant }

    var key: String {
        var phrase = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        if source == .assistant,
           let prefix = phrase.range(of: #"^\s*(?:(?:请|帮我|能否)\s*)?(?:查找|搜索|查|找|搜)(?:一下)?\s*"#,
                                     options: .regularExpression) {
            phrase.removeSubrange(prefix)
        }
        return phrase.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).joined()
    }

    func matches(_ other: Self) -> Bool {
        source == other.source && key == other.key && workspaceID == other.workspaceID &&
            root.standardizedFileURL.path == other.root.standardizedFileURL.path
    }
}

struct SearchFeedback: Codable, Identifiable, Equatable, Sendable {
    enum Rating: String, Codable, CaseIterable, Identifiable, Sendable {
        case relevant = "优先显示", irrelevant = "降低排序"
        var id: Self { self }
    }

    var id = UUID()
    var context: SearchMemoryContext
    var file: URL
    var rating: Rating
}

struct ProjectMemory: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var aliases: [String] = []
    var root: URL?
    var delivery: URL?
    var resumesLayout: Bool? = nil
    var recentLayout: TabSnapshot? = nil

    func matches(_ alias: String) -> Bool {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([name] + aliases).contains { $0.localizedCaseInsensitiveCompare(alias) == .orderedSame }
    }
}

@MainActor @Observable
final class AIMemory {
    static let shared = AIMemory(defaults: .standard)

    private struct Records: Codable {
        var feedback: [SearchFeedback] = []
        var projects: [ProjectMemory] = []
        var workflows: [FileWorkflow] = []
    }

    private let defaults: UserDefaults
    private let key = "wfolder.ai.memory.v1"
    private var records: Records
    var feedback: [SearchFeedback] { records.feedback }
    var projects: [ProjectMemory] { records.projects }
    var workflows: [FileWorkflow] { records.workflows }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        records = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Records.self, from: $0) } ?? Records()
    }

    func project(_ id: UUID?) -> ProjectMemory? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func project(named alias: String) -> ProjectMemory? {
        let matches = projects.filter { $0.matches(alias) }
        return matches.count == 1 ? matches.first : nil
    }

    func project(mentionedIn prompt: String?) -> ProjectMemory? {
        guard let prompt else { return nil }
        let matches = projects.filter { project in
            ([project.name] + project.aliases).contains { alias in
                guard alias.count > 1 else { return false }
                if alias.unicodeScalars.allSatisfy(\.isASCII) {
                    let token = NSRegularExpression.escapedPattern(for: alias)
                    return prompt.range(of: "(?<![A-Za-z0-9])" + token + "(?![A-Za-z0-9])",
                                        options: [.regularExpression, .caseInsensitive]) != nil
                }
                return prompt.localizedStandardContains(alias)
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func rating(for file: URL, in context: SearchMemoryContext) -> SearchFeedback.Rating? {
        feedback.first { $0.context.matches(context) && $0.file.standardizedFileURL.path == file.standardizedFileURL.path }?.rating
    }

    func rank(_ entries: [FileEntry], in context: SearchMemoryContext) -> [FileEntry]? {
        let matches = feedback.filter { $0.context.matches(context) }
        guard !matches.isEmpty else { return nil }
        let scores = Dictionary(matches.map { ($0.file.standardizedFileURL.path, $0.rating) },
                                uniquingKeysWith: { first, _ in first })
        var preferred: [FileEntry] = [], remaining: [FileEntry] = [], demoted: [FileEntry] = []
        for entry in entries {
            switch scores[entry.url.standardizedFileURL.path] {
            case .relevant: preferred.append(entry)
            case .irrelevant: demoted.append(entry)
            case nil: remaining.append(entry)
            }
        }
        guard !preferred.isEmpty || !demoted.isEmpty else { return nil }
        return preferred + remaining + demoted
    }

    @discardableResult func save(_ item: SearchFeedback) -> Bool {
        guard !item.context.key.isEmpty, item.context.root.isFileURL, item.file.isFileURL else { return false }
        records.feedback.removeAll { $0.id == item.id || ($0.context.matches(item.context)
            && $0.file.standardizedFileURL.path == item.file.standardizedFileURL.path) }
        records.feedback.insert(item, at: 0)
        persist()
        return true
    }

    func removeFeedback(_ id: UUID) {
        records.feedback.removeAll { $0.id == id }
        persist()
    }

    @discardableResult func save(_ project: ProjectMemory) -> Bool {
        guard !project.name.isEmpty, project.root?.isFileURL != false, project.delivery?.isFileURL != false,
              project.resumesLayout == true || project.root != nil || project.delivery != nil || !project.aliases.isEmpty else { return false }
        records.projects.removeAll { $0.id == project.id }
        records.projects.append(project)
        persist()
        return true
    }

    func rememberLayout(_ tab: TabSnapshot) {
        guard let id = tab.namedWorkspaceID, let index = records.projects.firstIndex(where: { $0.id == id }),
              records.projects[index].resumesLayout != false, records.projects[index].recentLayout != tab else { return }
        records.projects[index].recentLayout = tab
        persist()
    }

    func removeProject(_ id: UUID) {
        records.projects.removeAll { $0.id == id }
        persist()
    }

    @discardableResult func save(_ workflow: FileWorkflow) -> Bool {
        guard workflow.isValid, !workflows.contains(where: {
            $0.id != workflow.id && $0.name.localizedCaseInsensitiveCompare(workflow.name) == .orderedSame
        }) else { return false }
        if let index = records.workflows.firstIndex(where: { $0.id == workflow.id }) {
            records.workflows[index] = workflow
        } else {
            records.workflows.append(workflow)
        }
        persist()
        return true
    }

    func removeWorkflow(_ id: UUID) {
        records.workflows.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }
}
