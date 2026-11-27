import Foundation

struct PaneSnapshot: Codable, Equatable {
    let directory: URL
    let viewMode: FileViewMode
    let grouping: FileGrouping
    let sortColumn: FileColumn
    let ascending: Bool
    var isStash: Bool? = nil
    var smartFolder: SmartFolder? = nil
    var archiveURL: URL? = nil
    var mountedRoot: URL? = nil
    var viewSettings: FileViewSettings? = nil
}

indirect enum LayoutSnapshot: Codable, Equatable {
    case pane(PaneSnapshot)
    case split(PaneSplitDirection, Double, LayoutSnapshot, LayoutSnapshot)

    var folderPaths: [URL?] {
        switch self {
        case .pane(let pane):
            return [pane.isStash == true || pane.archiveURL != nil ? nil : pane.smartFolder?.root ?? pane.directory]
        case .split(_, _, let left, let right):
            return left.folderPaths + right.folderPaths
        }
    }
}

struct TabSnapshot: Codable, Equatable {
    let layout: LayoutSnapshot
    let activePane: Int
    let title: String?
    var comparisonPair: DirectoryPair? = nil
    var showsQuickAccess: Bool? = nil
    var namedWorkspaceID: UUID? = nil

    var preferredFolder: URL? {
        let directories = layout.folderPaths
        let active = directories.indices.contains(activePane) ? directories[activePane] : nil
        return active ?? directories.compactMap { $0 }.first
    }
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
    var organizationRules: [OrganizationRule] { read([OrganizationRule].self, key: "wfolder.organization.v1") ?? [] }
    func saveOrganizationRules(_ rules: [OrganizationRule]) { write(rules, key: "wfolder.organization.v1") }
    var remoteLocations: [RemoteLocation] { read([RemoteLocation].self, key: "wfolder.remoteLocations.v1") ?? [] }
    func saveRemoteLocations(_ locations: [RemoteLocation]) { write(locations, key: "wfolder.remoteLocations.v1") }
    var smartFolders: [SmartFolder] { read([SmartFolder].self, key: "wfolder.smartFolders.v1") ?? [] }
    func saveSmartFolders(_ folders: [SmartFolder]) { write(folders, key: "wfolder.smartFolders.v1") }

    var lastSession: SessionSnapshot? { read(SessionSnapshot.self, key: sessionKey) }
    var named: [NamedWorkspace] { read([NamedWorkspace].self, key: namesKey) ?? [] }
    var stash: [URL] { read([URL].self, key: stashKey) ?? [] }
    var pins: [QuickAccessPin] {
        read([QuickAccessPin].self, key: "wfolder.quickAccessPins") ??
            (defaults.stringArray(forKey: "favorites") ?? []).map {
                QuickAccessPin(url: URL(fileURLWithPath: $0, isDirectory: true), isFolder: true)
            }
    }
    var recentDestinations: [URL] { read([URL].self, key: "wfolder.recentDestinations") ?? [] }
    var folderViews: [String: FolderViewPreference] {
        read([String: FolderViewPreference].self, key: "wfolder.folderViews") ?? [:]
    }

    func saveFolderWorkspace(_ directory: URL) -> NamedWorkspace {
        var values = named
        if let existing = values.first(where: { saved in
            guard case .pane(let pane) = saved.tab.layout, pane.isStash != true, pane.smartFolder == nil,
                  pane.archiveURL == nil else { return false }
            return pane.directory.standardizedFileURL.path == directory.standardizedFileURL.path
        }) {
            return existing
        }
        let stem = directory.lastPathComponent.isEmpty || directory.path == "/" ? "磁盘" : directory.lastPathComponent
        let names = Set(values.map { $0.name.folding(options: .caseInsensitive, locale: .current) })
        var name = stem
        var number = 2
        while names.contains(name.folding(options: .caseInsensitive, locale: .current)) {
            name = "\(stem) \(number)"
            number += 1
        }
        let id = UUID()
        let pane = PaneSnapshot(directory: directory, viewMode: .details, grouping: .none, sortColumn: .name,
                                ascending: true)
        let tab = TabSnapshot(layout: .pane(pane), activePane: 0, title: name, namedWorkspaceID: id)
        let workspace = NamedWorkspace(id: id, name: name, tab: tab)
        values.append(workspace)
        saveNamed(values)
        return workspace
    }

    func saveSession(_ session: SessionSnapshot) { write(session, key: sessionKey) }
    func saveNamed(_ values: [NamedWorkspace]) { write(values, key: namesKey) }
    func saveStash(_ urls: [URL]) { write(urls, key: stashKey) }
    func savePins(_ pins: [QuickAccessPin]) { write(pins, key: "wfolder.quickAccessPins") }
    func saveRecentDestinations(_ urls: [URL]) { write(urls, key: "wfolder.recentDestinations") }
    func saveFolderViews(_ values: [String: FolderViewPreference]) { write(values, key: "wfolder.folderViews") }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

struct QuickAccessPin: Codable, Identifiable, Equatable {
    let url: URL
    let isFolder: Bool
    var id: String { url.path }
    var title: String { url.path == "/" ? "磁盘" : url.lastPathComponent }
}
