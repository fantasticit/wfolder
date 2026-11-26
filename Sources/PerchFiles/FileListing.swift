import Foundation

struct FileListing: Sendable {
    let id = UUID()
    let entries: [FileEntry]
    let rows: [URL: Int]

    init(entries: [FileEntry]) {
        self.entries = entries
        rows = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) },
                          uniquingKeysWith: { first, _ in first })
    }

    static func matching(_ entries: [FileEntry], query: String, filters: QuickSearchFilters = .init()) -> Self {
        guard !query.isEmpty || filters.isActive else { return Self(entries: entries) }
        let since = filters.date.since
        return Self(entries: entries.filter {
            filters.matches($0, since: since) && (query.isEmpty || matches(name: $0.name, filename: $0.filename, query: query))
        })
    }

    static func matches(name: String, filename: String, query: String) -> Bool {
        name.localizedStandardContains(query) || (filename != name && filename.localizedStandardContains(query))
    }
}

enum FolderSearchScope: String, CaseIterable, Identifiable, Sendable {
    case current = "仅当前目录"
    case descendants = "包含子目录"
    case workspace = "当前工作区"

    var id: Self { self }
}

enum QuickSearchDate: String, CaseIterable, Identifiable, Sendable {
    case anytime = "任意时间"
    case day = "最近 1 天"
    case week = "最近 7 天"
    case month = "最近 30 天"
    var id: Self { self }

    var since: Date? {
        switch self {
        case .anytime: return nil
        case .day: return Calendar.current.date(byAdding: .day, value: -1, to: .now)
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: .now)
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: .now)
        }
    }
}

struct QuickSearchFilters: Equatable, Sendable {
    var kind = SearchFileKind.any
    var date = QuickSearchDate.anytime
    var isActive: Bool { kind != .any || date != .anytime }

    func matches(_ entry: FileEntry, since: Date?) -> Bool {
        kind.matches(entry) && (since.map { cutoff in entry.modified.map { $0 >= cutoff } == true } ?? true)
    }
}

struct FolderSearchResults: Sendable {
    let entries: [FileEntry]
    let unreadable: Int
}

struct FolderSearchProgress: Sendable {
    let scanned: Int
    let firstMatches: [FileEntry]?
}

struct DirectoryContents: Sendable {
    let entries: [FileEntry]
    let visible: FileListing
}
