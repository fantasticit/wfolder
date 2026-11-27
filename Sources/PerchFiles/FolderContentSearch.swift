import Foundation

struct FolderContentSearch: Sendable {
    static let matchLimit = 500

    let roots: [URL]
    let scope: FolderSearchScope
    let showHidden: Bool
    let storage: ProfessionalStorage

    func search(_ query: String, filters: QuickSearchFilters, refreshIndex: Bool) throws -> FolderSearchResults {
        let cutoff = filters.date.since
        var entries: [URL: FileEntry] = [:]
        var matches: [URL: [ContentIndex.Match]] = [:]
        var matchedSections = 0
        var unreadable = 0
        var firstFailure: Error?
        var completed = false
        for root in scope == .workspace ? FileSystem.selectedRoots(roots) : roots {
            try Task.checkCancellation()
            let index = ContentIndex(root: root, storage: storage, includesDescendants: scope != .current, showHidden: showHidden)
            do {
                let coverage: ContentIndex.Coverage
                if !refreshIndex, let existing = try index.coverage() { coverage = existing }
                else { coverage = try index.rebuild(progress: TransferMeter()) }
                let found = try index.search(query, limit: Self.matchLimit + 1 - matchedSections) { url in
                    let entry = FileEntry.read(url, presentedAs: url.standardizedFileURL)
                    guard filters.matches(entry, since: cutoff) else { return false }
                    entries[entry.id] = entry
                    return true
                }
                completed = true
                unreadable += coverage.partial
                for hit in found {
                    let id = hit.url.standardizedFileURL
                    matchedSections += 1
                    if matchedSections <= Self.matchLimit { matches[id, default: []].append(hit) }
                }
                if matchedSections > Self.matchLimit { break }
            } catch {
                try Task.checkCancellation()
                unreadable += 1
                if firstFailure == nil { firstFailure = error }
            }
        }
        if !completed, let firstFailure { throw firstFailure }
        return FolderSearchResults(entries: entries.values.filter { matches[$0.id] != nil }, unreadable: unreadable,
                                   contentMatches: matches, reachedLimit: matchedSections > Self.matchLimit)
    }
}
