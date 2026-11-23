import Foundation
import UniformTypeIdentifiers

struct FileEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let filename: String
    let isFolder: Bool
    let kind: String
    let modified: Date?
    let size: Int?
    let contentType: UTType?

    var id: URL { url }
    var sizeLabel: String {
        size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }

    func displayName(showExtensions: Bool) -> String {
        let ext = url.pathExtension
        guard !isFolder, !ext.isEmpty else { return name }
        let hasExtension = (name as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame
        if showExtensions { return hasExtension ? name : name + "." + ext }
        return hasExtension ? (name as NSString).deletingPathExtension : name
    }

    static func read(_ url: URL, presentedAs logicalURL: URL? = nil) -> Self {
        let info = try? url.resourceValues(forKeys: FileSystem.keys)
        let filename = url.lastPathComponent
        let type = info?.contentType
        let isLink = info?.isSymbolicLink == true
        let isPackage = info?.isPackage == true
        let linkTarget = isLink ? try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) : nil
        let isFolder = !isPackage && (info?.isDirectory == true
            || (linkTarget?.isDirectory == true && linkTarget?.isPackage != true))
        let kind: String
        if isLink {
            kind = "符号链接"
        } else if isFolder {
            kind = "文件夹"
        } else if let format = NewFileFormat(rawValue: url.pathExtension.lowercased()) {
            kind = format.title
        } else if isPackage {
            kind = type?.localizedDescription ?? "包"
        } else {
            kind = type?.localizedDescription ?? "文件"
        }
        return Self(
            url: logicalURL ?? url, name: info?.localizedName ?? filename, filename: filename,
            isFolder: isFolder, kind: kind, modified: info?.contentModificationDate,
            size: (isFolder || isPackage) ? nil : info?.fileSize, contentType: type
        )
    }
}

enum FileSystem {
    private struct DirectoryLocation {
        let logical: URL
        let disk: URL
        private let diskPrefix: String

        init(_ directory: URL) {
            logical = directory
            disk = FileSystem.physicalDirectory(directory)
            diskPrefix = disk.path == "/" ? "/" : disk.path + "/"
        }

        func logicalURL(for physicalURL: URL) -> URL {
            guard disk.path != logical.path, physicalURL.path.hasPrefix(diskPrefix) else { return physicalURL }
            let relative = physicalURL.path.dropFirst(diskPrefix.count)
            return logical.appendingPathComponent(String(relative), isDirectory: physicalURL.hasDirectoryPath)
        }
    }

    static let keys: Set<URLResourceKey> = [
        .localizedNameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .contentTypeKey, .contentModificationDateKey, .fileSizeKey
    ]

    static func physicalDirectory(_ directory: URL) -> URL {
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return directory.standardizedFileURL }
            defer { free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
        }
    }

    static func list(_ url: URL, showHidden: Bool) throws -> [FileEntry] {
        let location = DirectoryLocation(url)
        let urls = try FileManager.default.contentsOfDirectory(
            at: location.disk, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return try urls.map { url in
            try Task.checkCancellation()
            return FileEntry.read(url, presentedAs: location.logicalURL(for: url))
        }
    }

    static func subfolders(_ directory: URL, showHidden: Bool) throws -> [Place] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedNameKey]
        let location = DirectoryLocation(directory)
        let urls = try FileManager.default.contentsOfDirectory(at: location.disk, includingPropertiesForKeys: Array(keys),
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return try urls.compactMap { url -> Place? in
            try Task.checkCancellation()
            guard let info = try? url.resourceValues(forKeys: keys), info.isDirectory == true,
                  info.isPackage != true, info.isSymbolicLink != true else { return nil }
            return Place(name: info.localizedName ?? url.lastPathComponent, symbol: "folder", url: location.logicalURL(for: url))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func search(_ directory: URL, query: String, showHidden: Bool) throws -> FolderSearchResults {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        let location = DirectoryLocation(directory)
        var unreadable = 0
        guard let iterator = FileManager.default.enumerator(at: location.disk,
                includingPropertiesForKeys: Array(keys), options: options, errorHandler: { _, _ in
                    unreadable += 1
                    return !Task.isCancelled
                }) else { throw CocoaError(.fileReadUnknown) }
        var matches: [FileEntry] = []
        for case let url as URL in iterator {
            try Task.checkCancellation()
            let filename = url.lastPathComponent
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? filename
            if FileListing.matches(name: name, filename: filename, query: query) {
                matches.append(FileEntry.read(url, presentedAs: location.logicalURL(for: url)))
            }
        }
        try Task.checkCancellation()
        return FolderSearchResults(entries: matches, unreadable: unreadable)
    }

    static func selectedRoots(_ urls: [URL]) -> [URL] {
        let selected = Set(urls.map { $0.standardizedFileURL.path })
        return urls.filter { url in
            var parent = url.standardizedFileURL.deletingLastPathComponent()
            while parent.path != "/" && !parent.path.isEmpty {
                if selected.contains(parent.path) { return false }
                parent.deleteLastPathComponent()
            }
            return !selected.contains("/") || url.path == "/"
        }
    }

    static func validateName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FileActionError.invalidName
        }
        return name
    }

    static func makeFolder(in directory: URL, name: String) throws -> URL {
        let target = directory.appendingPathComponent(try validateName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    static func makeFile(in directory: URL, name: String, format: NewFileFormat,
                         templates: URL? = Bundle.main.resourceURL?.appendingPathComponent("Templates")) throws -> URL {
        let name = try validateName(name)
        let suffix = "." + format.rawValue
        let filename = name.lowercased().hasSuffix(suffix) ? name : name + suffix
        let target = directory.appendingPathComponent(filename, isDirectory: false)
        let bytes = try format.contents(templates: templates)
        let stagingDirectory = directory.appendingPathComponent(".perch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let temporary = stagingDirectory.appendingPathComponent("file", isDirectory: false)
        try bytes.write(to: temporary)
        try moveExclusive(from: temporary, to: target)
        return target
    }

    static func rename(_ entry: FileEntry, name: String) throws -> URL {
        let name = try validateName(name)
        guard name != entry.filename else { return entry.url }
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: entry.isFolder)
        try moveExclusive(from: entry.url, to: target)
        return target
    }

    static func moveExclusive(from original: URL, to target: URL) throws {
        // This also handles case-only renames on a case-insensitive volume.
        let result = original.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination in
                renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func duplicate(_ entry: FileEntry) throws -> URL {
        try copyWithAvailableName(entry, into: entry.url.deletingLastPathComponent(), move: false)
    }

    static func copyWithAvailableName(_ entry: FileEntry, into directory: URL, move: Bool) throws -> URL {
        let ext = entry.isFolder ? "" : entry.url.pathExtension
        let stem = ext.isEmpty ? entry.filename : entry.url.deletingPathExtension().lastPathComponent
        for number in 1...10_000 {
            let suffix = number == 1 ? " 副本" : " 副本 \(number)"
            let filename = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            do {
                return try paste(entry.url, into: directory, move: move, name: filename)
            } catch where isNameConflict(error) {
                continue
            }
        }
        throw FileActionError.duplicateLimit
    }

    static func isNameConflict(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteFileExists.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST))
    }

    static func paste(_ source: URL, into directory: URL, move: Bool, name: String? = nil) throws -> URL {
        let originalParent = source.deletingLastPathComponent().resolvingSymlinksInPath().path
        let canonicalDirectory = directory.resolvingSymlinksInPath().path
        let canonicalSource = source.resolvingSymlinksInPath().path
        if move && name == nil && originalParent == canonicalDirectory { return source }
        let entry = FileEntry.read(source)
        let target = directory.appendingPathComponent(name ?? entry.filename, isDirectory: entry.isFolder)
        if entry.isFolder && (canonicalDirectory == canonicalSource
            || canonicalDirectory.hasPrefix(canonicalSource == "/" ? "/" : canonicalSource + "/")) {
            throw FileActionError.recursiveCopy
        }
        if move {
            do {
                try moveExclusive(from: source, to: target)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && [Int(EXDEV), Int(ENOTSUP)].contains(error.code) {
                try FileManager.default.moveItem(at: source, to: target)
            }
        } else {
            try FileManager.default.copyItem(at: source, to: target)
        }
        return target
    }
}

enum FileActionError: LocalizedError {
    case invalidName, recursiveCopy, duplicateLimit, templateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidName: return "请输入有效的名称，名称不能包含斜线或冒号。"
        case .recursiveCopy: return "无法将文件夹复制或移动到其自身或子文件夹。"
        case .duplicateLimit: return "无法为副本生成可用的名称。"
        case .templateUnavailable: return "无法读取此格式的文件模板。"
        }
    }
}
