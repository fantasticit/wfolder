import Foundation
import Observation

struct WorkflowTemplate: Codable, Sendable {
    let version: Int
    let title: String
    let rename: BatchRenameRule?
    let zip: Bool
    let transfer: FileWorkflow.Transfer
    let usesProjectDelivery: Bool

    init(_ workflow: FileWorkflow) {
        version = 1
        title = workflow.name
        rename = workflow.rename
        zip = workflow.compresses
        transfer = workflow.transfer
        usesProjectDelivery = workflow.usesProjectDelivery
    }

    func draft() throws -> FileWorkflow {
        guard version == 1, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 80, rename != nil || zip || transfer != .none,
              [rename?.text, rename?.replacement, rename?.start].compactMap({ $0 }).allSatisfy({ $0.count <= 255 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return FileWorkflow(name: title, rename: rename, compresses: zip, transfer: transfer,
                            destination: nil, usesProjectDelivery: usesProjectDelivery)
    }

    static func read(_ url: URL) throws -> FileWorkflow {
        guard let stamp = FileStamp(url), stamp.regular, stamp.bytes <= 64 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let input = try VerifiedFile.open(url, stamp: stamp)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: 64 * 1024) ?? Data()
        return try JSONDecoder().decode(Self.self, from: bytes).draft()
    }
}

@MainActor @Observable
final class ProjectInbox {
    struct Item: Identifiable, Sendable {
        let url: URL
        let stamp: FileStamp
        var id: URL { url }
    }

    private struct Preferences: Codable {
        var folder: URL?
        var destinations: [String: UUID] = [:]
        var ignored: [String: FileStamp] = [:]
    }

    private let storage: ProfessionalStorage
    private var preferences = Preferences()
    private(set) var items: [Item] = []
    private(set) var issue: String?
    var folder: URL? { preferences.folder }
    private var previous: [URL: FileStamp] = [:]
    private var scanning = false

    init(storage: ProfessionalStorage) {
        self.storage = storage
        do { preferences = try storage.load(Preferences.self, "inbox.json") ?? Preferences() }
        catch { issue = "无法读取收件箱配置。" }
    }

    func watch(_ directory: URL?) {
        var next = preferences
        next.folder = directory?.standardizedFileURL
        next.ignored = [:]
        if save(next) {
            items = []
            previous = [:]
        }
    }

    func refresh() async {
        guard let folder, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            let candidates = try await Task.detached(priority: .utility) {
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
                    .compactMap { url -> Item? in
                        let temporary = ["download", "crdownload", "part", "tmp"]
                        guard !temporary.contains(url.pathExtension.lowercased()),
                              let stamp = FileStamp(url), stamp.regular else { return nil }
                        return Item(url: url.standardizedFileURL, stamp: stamp)
                    }
            }.value
            guard folder == self.folder else { return }
            let stable = candidates.filter { previous[$0.url] == $0.stamp && preferences.ignored[$0.url.path] != $0.stamp }
            items = stable.sorted { $0.stamp.modified > $1.stamp.modified }
            previous = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url, $0.stamp) })
            issue = nil
        } catch {
            if folder == self.folder {
                items = []
                issue = "收件箱不可用。\(error.localizedDescription)"
            }
        }
    }

    func suggestion(for item: Item, projects: [ProjectMemory]) -> (UUID, String)? {
        let lower = item.url.deletingPathExtension().lastPathComponent
        let byName = projects.filter { project in
            ([project.name] + project.aliases).contains { alias in
                alias.count >= 2 && lower.localizedCaseInsensitiveContains(alias)
            }
        }
        if byName.count == 1, let project = byName.first { return (project.id, "名称匹配项目") }
        let ext = item.url.pathExtension.lowercased()
        if let remembered = preferences.destinations[ext], projects.contains(where: { $0.id == remembered }) {
            return (remembered, "之前归档过相同格式")
        }
        return nil
    }

    func dismiss(_ item: Item) {
        var next = preferences
        next.ignored[item.url.path] = item.stamp
        if next.ignored.count > 1_000 {
            next.ignored = Dictionary(uniqueKeysWithValues: next.ignored.sorted { $0.value.modified > $1.value.modified }
                .prefix(1_000).map { ($0.key, $0.value) })
        }
        if save(next) { items.removeAll { $0.id == item.id } }
    }

    func remember(_ item: Item, project: UUID) {
        items.removeAll { $0.id == item.id }
        let ext = item.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return }
        var next = preferences
        next.destinations[ext] = project
        _ = save(next)
    }

    private func save(_ next: Preferences) -> Bool {
        do { try storage.save(next, "inbox.json") }
        catch { issue = error.localizedDescription; return false }
        preferences = next
        issue = nil
        return true
    }
}
