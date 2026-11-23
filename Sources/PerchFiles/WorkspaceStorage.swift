import Foundation

struct PaneSnapshot: Codable, Equatable {
    let directory: URL
    let viewMode: FileViewMode
    let grouping: FileGrouping
    let sortColumn: FileColumn
    let ascending: Bool
    var isStash: Bool? = nil
}

indirect enum LayoutSnapshot: Codable, Equatable {
    case pane(PaneSnapshot)
    case split(PaneSplitDirection, Double, LayoutSnapshot, LayoutSnapshot)
}

struct TabSnapshot: Codable, Equatable {
    let layout: LayoutSnapshot
    let activePane: Int
    let title: String?
}

struct SessionSnapshot: Codable, Equatable {
    let tabs: [TabSnapshot]
    let activeTab: Int
    let showsPreview: Bool
}

struct NamedWorkspace: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let tab: TabSnapshot
}

struct WorkspaceStorage {
    let defaults: UserDefaults
    private let sessionKey = "wfolder.session.v1"
    private let namesKey = "wfolder.workspaces.v1"
    private let stashKey = "wfolder.stash.v1"

    var lastSession: SessionSnapshot? { read(SessionSnapshot.self, key: sessionKey) }
    var named: [NamedWorkspace] { read([NamedWorkspace].self, key: namesKey) ?? [] }
    var stash: [URL] { read([URL].self, key: stashKey) ?? [] }

    func saveSession(_ session: SessionSnapshot) { write(session, key: sessionKey) }
    func saveNamed(_ values: [NamedWorkspace]) { write(values, key: namesKey) }
    func saveStash(_ urls: [URL]) { write(urls, key: stashKey) }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
