import Foundation
import UniformTypeIdentifiers

struct SearchSemantics: Codable, Equatable, Sendable {
    let concepts: [[String]]

    @MainActor func indexedMatches(in root: URL) async throws -> [Set<String>] {
        let queries = concepts.map { aliases in
            let query = SpotlightSearch()
            let predicates = aliases.map { SpotlightField.contents.predicate(for: $0) }
            query.start(predicate: NSCompoundPredicate(orPredicateWithSubpredicates: predicates), directories: [root])
            return query
        }
        defer { queries.forEach { $0.cancel() } }
        let deadline = ContinuousClock.now + .seconds(2)
        while queries.contains(where: \.busy), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return queries.map { Set($0.hits.map(\.path)) }
    }

    func matcher(in root: URL, readsContents: Bool, indexed: [Set<String>]) -> (FileEntry) -> Bool {
        let patterns = concepts.map(Self.pattern)
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let physicalRoot = FileSystem.physicalDirectory(root).path
        return { entry in
            let path = entry.url.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : entry.filename
            let indexedPath = physicalRoot == root.path ? path : (physicalRoot as NSString).appendingPathComponent(relative)
            let label = root.lastPathComponent + "/" + relative + "/" + entry.name
            let labelRange = NSRange(label.startIndex..., in: label)
            let missing = patterns.indices.filter { index in
                patterns[index]?.firstMatch(in: label, range: labelRange) == nil &&
                    (!indexed.indices.contains(index) || !indexed[index].contains(indexedPath))
            }
            if missing.isEmpty { return true }
            guard readsContents, let text = Self.localExcerpt(of: entry) else { return false }
            let contentRange = NSRange(text.startIndex..., in: text)
            return missing.allSatisfy { index in patterns[index]?.firstMatch(in: text, range: contentRange) != nil }
        }
    }

    private static func pattern(_ aliases: [String]) -> NSRegularExpression? {
        let variants = aliases.map { alias in
            alias.split(whereSeparator: { $0.isWhitespace || "-_/".contains($0) })
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[\s_/-]+"#)
        }
        return try? NSRegularExpression(pattern: variants.joined(separator: "|"), options: .caseInsensitive)
    }

    private static func localExcerpt(of entry: FileEntry) -> String? {
        guard !entry.isFolder, entry.cloudStatus != .online,
              entry.contentType?.conforms(to: .text) == true || entry.isMarkdown || entry.sourceLanguage != nil,
              let values = try? entry.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: entry.url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum SearchProjectLocation {
    private enum Source: Int, Sendable {
        case spotlight, documents, workspace, current
    }

    private struct Candidate: Sendable {
        let url: URL
        let source: Source
    }

    @MainActor static func find(_ name: String, current: URL, knownRoots: [URL]) async throws -> URL? {
        let nearby = await nearbyProjects(named: name, current: current, knownRoots: knownRoots)
        if let known = try await best(nearby, name: name, repositoriesOnly: true) { return known }
        async let documents = documentProjects(named: name)
        let query = SpotlightSearch()
        query.start(predicate: NSPredicate(format: "%K ==[cd] %@ AND ANY %K == %@",
                                           NSMetadataItemFSNameKey, name, NSMetadataItemContentTypeTreeKey,
                                           UTType.folder.identifier), directories: [BrowserModel.home])
        defer { query.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while query.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let documentResult = await documents
        try Task.checkCancellation()
        let indexed = query.hits.map { Candidate(url: $0.url, source: .spotlight) }
        let documentCandidates = (try? documentResult.get()) ?? []
        if let project = try await best(nearby + documentCandidates + indexed, name: name) { return project }
        if case .failure(let error) = documentResult, isPermissionError(error) {
            throw AIActionError.projectLookupNeedsAccess(name)
        }
        if isApplicationCache(current) { throw AIActionError.projectNotFound(name) }
        return nil
    }

    private static func nearbyProjects(named name: String, current: URL, knownRoots: [URL]) async -> [Candidate] {
        await Task.detached(priority: .userInitiated) {
            let roots = [Candidate(url: current, source: .current)] + knownRoots.map { Candidate(url: $0, source: .workspace) }
            return roots.compactMap { root in
                var parent = root.url.standardizedFileURL
                while parent.path != "/" {
                    if parent.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame {
                        return Candidate(url: parent, source: root.source)
                    }
                    parent.deleteLastPathComponent()
                }
                let child = root.url.appendingPathComponent(name, isDirectory: true)
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
                return Candidate(url: child, source: root.source)
            }
        }.value
    }

    private static func documentProjects(named name: String) async -> Result<[Candidate], Error> {
        let worker = Task.detached(priority: .userInitiated) { try scanDocuments(named: name) }
        return await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
    }

    private static func scanDocuments(named name: String) throws -> [Candidate] {
        let documents = URL.documentsDirectory
        var rootError: Error?
        guard let iterator = FileManager.default.enumerator(at: documents,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if url.path == documents.path {
                    rootError = error
                    return false
                }
                return !Task.isCancelled
            }) else { throw rootError ?? CocoaError(.fileReadUnknown) }
        var candidates = [Candidate]()
        for case let url as URL in iterator {
            try Task.checkCancellation()
            // Include projects directly in Documents or in one grouping folder such as Documents/code.
            if iterator.level >= 2 { iterator.skipDescendants() }
            if url.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                candidates.append(Candidate(url: url, source: .documents))
                iterator.skipDescendants()
            }
        }
        if let rootError { throw rootError }
        return candidates
    }

    private static func best(_ options: [Candidate], name: String, repositoriesOnly: Bool = false) async throws -> URL? {
        let candidates = await Task.detached(priority: .userInitiated) {
            var ranks = [URL: Int]()
            for option in options {
                guard option.url.lastPathComponent.localizedCaseInsensitiveCompare(name) == .orderedSame,
                      !isApplicationCache(option.url) else { continue }
                let url = option.url.resolvingSymlinksInPath()
                guard !isApplicationCache(url),
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                      values.isDirectory == true, values.isPackage != true else { continue }
                let repository = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
                if repositoriesOnly && !repository { continue }
                let score = (repository ? 4 : 0) + option.source.rawValue
                ranks[url] = max(score, ranks[url] ?? score)
            }
            return ranks.sorted { $0.value > $1.value }
        }.value
        try Task.checkCancellation()
        guard let first = candidates.first else { return nil }
        guard candidates.dropFirst().first?.value != first.value else {
            throw AIActionError.ambiguousProject(name)
        }
        return first.key
    }

    private static func isApplicationCache(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        if parts.contains(".cache") { return true }
        guard let cacheIndex = parts.lastIndex(where: { $0 == "cache" || $0 == "caches" }) else { return false }
        let parents = parts[..<cacheIndex]
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        return parents.contains("user data") || parents.contains("application support") || url.path.hasPrefix(library + "/")
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError ||
            failure.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(failure.code)
    }
}
