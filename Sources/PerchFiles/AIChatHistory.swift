import Foundation

struct AIChatRoute: Codable, Equatable {
    let provider: AIProvider
    let endpoint: URL
    let model: String

    init(_ connection: AIConnection) {
        provider = connection.provider
        endpoint = connection.endpoint
        model = connection.model
    }
}

struct AISearchSummary: Codable, Sendable {
    let folder: SmartFolder
    let count: Int
    let unreadable: Int
    let samples: [String]

    init(folder: SmartFolder, results: FolderSearchResults) {
        self.folder = folder
        count = results.entries.count
        unreadable = results.unreadable
        let prefix = folder.root.path == "/" ? "/" : folder.root.path + "/"
        samples = results.entries.prefix(5).map { entry in
            let path = entry.url.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : entry.name
        }
    }

    var title: String { count == 0 ? "没有匹配的文件" : "找到 \(count) 项匹配" }

    var details: [String] {
        var lines = ["搜索已完成（可访问范围）", "搜索目录  " + (folder.root.path == "/" ? "本机 /" : folder.root.path)]
        lines += folder.conditions.aiDetails
        lines += samples
        if count > samples.count { lines.append("还有 \(count - samples.count) 项可在结果面板查看。") }
        if unreadable > 0 { lines.append("\(unreadable) 个目录无法读取，结果仅包含可访问的文件。") }
        return lines
    }

    var providerContext: String {
        "Completed. Match count: \(count). Unreadable directories: \(unreadable). Use searchResults to show file names locally."
    }
}

struct AIChatRecord: Codable, Identifiable {
    struct Turn: Codable {
        enum Reply: Codable {
            case interrupted, stopped
            case answer(String), failed(String)
            case searchResult(AISearchSummary)
            case organizationResult(title: String, details: [String])
            case proposal(title: String, details: [String])
            case archived(title: String, details: [String], status: String)
        }

        let id: UUID
        let prompt: String
        let preface: String?
        let reply: Reply
    }

    let id: UUID
    let updated: Date
    let turns: [Turn]
    let route: AIChatRoute?
    let exchanges: [AIExchange]

    var title: String {
        let firstLine = turns.first?.prompt.split(whereSeparator: \.isNewline).first
        return firstLine.map { String($0.prefix(60)) } ?? "新对话"
    }
}

struct AIChatHistory {
    let directory: URL
    private let defaults: UserDefaults
    private static let selectionKey = "wfolder.ai.activeConversation.v1"

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let appID = Bundle.main.bundleIdentifier ?? "local.perchfiles.browser"
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent(appID, isDirectory: true)
            .appendingPathComponent("AI Conversations", isDirectory: true)
        self.defaults = defaults
    }

    var selectedID: UUID? { defaults.string(forKey: Self.selectionKey).flatMap(UUID.init(uuidString:)) }

    func select(_ id: UUID) { defaults.set(id.uuidString, forKey: Self.selectionKey) }

    func restore() -> (records: [AIChatRecord], failed: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return ([], false) }
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]) else { return ([], true) }
        var records = [AIChatRecord]()
        var failed = false
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(AIChatRecord.self, from: data), record.id == id else {
                failed = true
                continue
            }
            records.append(record)
        }
        return (records.sorted { $0.updated > $1.updated }, failed)
    }

    func save(_ record: AIChatRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: location(record.id), options: [.atomic])
    }

    func delete(_ id: UUID) throws {
        let url = location(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func location(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}
