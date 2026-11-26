import Foundation
import Observation

@MainActor @Observable
final class FrequentFiles {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let file: FileEntry
    }

    private struct Visit: Codable, Sendable {
        var url: URL
        var score: Double
        var lastOpened: Date
        var inTrash = false

        func weight(at date: Date) -> Double {
            let age = max(0, date.timeIntervalSince(lastOpened))
            return score * pow(0.5, age / (14 * 86_400))
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "wfolder.frequentFiles.v1"
    private var visits: [String: Visit]
    private(set) var items: [Item] = []
    private(set) var recentItems: [Item] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        visits = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([String: Visit].self, from: $0)
        } ?? [:]
    }

    deinit { refreshTask?.cancel() }

    func recordOpen(_ url: URL, at now: Date = .now) {
        recordOpen([url], at: now)
    }

    func recordOpen(_ urls: [URL], at now: Date = .now) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        for url in files {
            let key = FileSystem.locationKey(url)
            let visit = visits[key]
            visits[key] = Visit(url: url, score: (visit?.weight(at: now) ?? 0) + 1,
                                lastOpened: max(now, visit?.lastOpened ?? now))
        }
        saveAndRefresh(at: now)
    }

    func remove(_ item: Item) {
        guard visits.removeValue(forKey: item.id) != nil else { return }
        saveAndRefresh()
    }

    func relocate(_ changes: [FileRelocation], trashing: Bool = false, restoring: Bool = false) {
        guard !visits.isEmpty, !changes.isEmpty else { return }
        let moves = changes.map { change in
            let source = restoring ? change.current : change.original
            let target = restoring ? change.original : change.current
            return (source: FileSystem.locationKey(source), target: target, directory: change.stamp?.directory == true)
        }
        let exact = Dictionary(moves.map { ($0.source, $0.target) }, uniquingKeysWith: { _, last in last })
        let directories = moves.filter(\.directory).sorted { $0.source.count > $1.source.count }
        var updated = visits
        var relocated: [String: Visit] = [:]
        for (key, var visit) in visits {
            let target: URL?
            if let match = exact[key] {
                target = match
            } else if let parent = directories.first(where: { key.hasPrefix($0.source + "/") }) {
                target = parent.target.appendingPathComponent(String(key.dropFirst(parent.source.count + 1)))
            } else {
                continue
            }
            guard let target else { continue }
            updated.removeValue(forKey: key)
            visit.url = target
            visit.inTrash = trashing
            relocated[FileSystem.locationKey(target)] = visit
        }
        guard !relocated.isEmpty else { return }
        updated.merge(relocated, uniquingKeysWith: { _, moved in moved })
        visits = updated
        saveAndRefresh()
    }

    func refresh(at now: Date = .now) {
        refreshTask?.cancel()
        let ranked = rankedVisits(at: now).filter { !$0.value.inTrash }
        if ranked.isEmpty {
            items = []
            recentItems = []
            return
        }
        let worker = Task.detached(priority: .utility) {
            var loaded: [String: Item] = [:]
            func read(_ ranked: [(key: String, value: Visit)], limit: Int) -> [Item] {
                var available: [Item] = []
                for (key, visit) in ranked {
                    guard !Task.isCancelled else { break }
                    if let item = loaded[key] { available.append(item) }
                    else if FileManager.default.fileExists(atPath: visit.url.path) {
                        let file = FileEntry.read(visit.url)
                        guard !file.isFolder else { continue }
                        let item = Item(id: key, file: file)
                        loaded[key] = item
                        available.append(item)
                    }
                    if available.count == limit { break }
                }
                return available
            }
            let recent = ranked.sorted {
                if $0.value.lastOpened != $1.value.lastOpened { return $0.value.lastOpened > $1.value.lastOpened }
                return $0.key < $1.key
            }
            return (read(ranked, limit: 6), read(recent, limit: 15))
        }
        refreshTask = Task { [weak self] in
            let available = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            if self?.items != available.0 { self?.items = available.0 }
            if self?.recentItems != available.1 { self?.recentItems = available.1 }
        }
    }

    private func saveAndRefresh(at now: Date = .now) {
        visits = Dictionary(uniqueKeysWithValues: rankedVisits(at: now).prefix(180).map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(visits) { defaults.set(data, forKey: storageKey) }
        refresh(at: now)
    }

    private func rankedVisits(at now: Date) -> [(key: String, value: Visit)] {
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        return visits.filter { $0.value.lastOpened >= cutoff }.sorted {
            let a = $0.value.weight(at: now)
            let b = $1.value.weight(at: now)
            if a != b { return a > b }
            if $0.value.lastOpened != $1.value.lastOpened { return $0.value.lastOpened > $1.value.lastOpened }
            return $0.key < $1.key
        }
    }
}
