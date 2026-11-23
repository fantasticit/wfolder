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

    static func matching(_ entries: [FileEntry], query: String) -> Self {
        guard !query.isEmpty else { return Self(entries: entries) }
        return Self(entries: entries.filter {
            matches(name: $0.name, filename: $0.filename, query: query)
        })
    }

    static func matches(name: String, filename: String, query: String) -> Bool {
        name.localizedStandardContains(query) || (filename != name && filename.localizedStandardContains(query))
    }
}

enum FolderSearchScope: String, CaseIterable, Identifiable, Sendable {
    case current = "仅当前目录"
    case descendants = "包含子目录"

    var id: Self { self }
}

struct FolderSearchResults: Sendable {
    let entries: [FileEntry]
    let unreadable: Int
}

struct DirectoryContents: Sendable {
    let entries: [FileEntry]
    let visible: FileListing
}
