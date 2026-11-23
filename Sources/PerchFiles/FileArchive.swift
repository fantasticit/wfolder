import Foundation

enum FileArchive {
    private static let tar = "/usr/bin/tar"
    private static let archiveSuffixes = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma",
        ".zip", ".tar", ".tgz", ".tbz", ".tbz2", ".txz", ".tzst", ".7z", ".rar"
    ]
    private static let decompressors = [".gz": "/usr/bin/gzip", ".bz2": "/usr/bin/bzip2"]

    static func canExtract(_ url: URL) -> Bool { suffix(for: url) != nil }

    static func compress(_ sources: [URL], in directory: URL) throws -> URL {
        let parent = directory.standardizedFileURL.path
        let prefix = parent == "/" ? "/" : parent + "/"
        guard let first = sources.first,
              sources.allSatisfy({
                  let path = $0.standardizedFileURL.path
                  return path.hasPrefix(prefix) && path.count > prefix.count
              }) else {
            throw ArchiveError.invalidSelection
        }
        return try withStaging(in: directory) { staging in
            let temporary = staging.appendingPathComponent("archive.zip")
            let fileList = staging.appendingPathComponent("files")
            var names = Data()
            for source in FileSystem.selectedRoots(sources) {
                let relativePath = source.standardizedFileURL.path.dropFirst(prefix.count)
                names.append(contentsOf: ("./" + relativePath).utf8)
                names.append(0)
            }
            try names.write(to: fileList)
            try run(tar, arguments: ["-c", "--format", "zip", "--no-mac-metadata",
                                     "-f", temporary.path, "-C", directory.path, "--null", "-T", fileList.path],
                    staging: staging)
            let name = sources.count == 1 ? first.lastPathComponent : "归档"
            return try publish(temporary, in: directory, name: name, extension: ".zip")
        }
    }

    static func extract(_ source: URL) throws -> URL {
        guard let suffix = suffix(for: source) else { throw ArchiveError.unsupported }
        let directory = source.deletingLastPathComponent()
        let stem = String(source.lastPathComponent.dropLast(suffix.count))
        let name = stem.isEmpty || stem == "." || stem == ".." ? "解压文件" : stem
        return try withStaging(in: directory) { staging in
            let temporary = staging.appendingPathComponent("contents")
            if let decompressor = decompressors[suffix] {
                try Data().write(to: temporary)
                let output = try FileHandle(forWritingTo: temporary)
                defer { try? output.close() }
                try run(decompressor, arguments: ["-dc", "--", source.path], staging: staging, output: output)
                let stemURL = URL(fileURLWithPath: name)
                let ext = stemURL.pathExtension
                return try publish(temporary, in: directory,
                                   name: ext.isEmpty ? name : stemURL.deletingPathExtension().lastPathComponent,
                                   extension: ext.isEmpty ? "" : "." + ext)
            }
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            // bsdtar retains its default path and symlink protections. The extraction directory starts empty.
            try run(tar, arguments: ["-x", "-f", source.path, "-C", temporary.path,
                                     "--no-same-owner", "--no-same-permissions", "--no-acls",
                                     "--no-fflags", "--no-xattrs", "--no-mac-metadata"], staging: staging)
            return try publish(temporary, in: directory, name: name, extension: "")
        }
    }

    private static func suffix(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return archiveSuffixes.first(where: name.hasSuffix) ?? decompressors.keys.first(where: name.hasSuffix)
    }

    private static func withStaging(in directory: URL, _ operation: (URL) throws -> URL) throws -> URL {
        let staging = directory.appendingPathComponent(".perch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        return try operation(staging)
    }

    static func publish(_ temporary: URL, in directory: URL, name: String, extension ext: String) throws -> URL {
        for number in 1...10_000 {
            let suffix = number == 1 ? "" : " \(number)"
            let destination = directory.appendingPathComponent(name + suffix + ext)
            do {
                try FileSystem.moveExclusive(from: temporary, to: destination)
                return destination
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                continue
            }
        }
        throw ArchiveError.nameUnavailable
    }

    private static func run(_ executable: String, arguments: [String], staging: URL,
                            output: FileHandle = .nullDevice) throws {
        let log = staging.appendingPathComponent("error.log")
        try Data().write(to: log)
        let diagnostics = try FileHandle(forUpdating: log)
        defer { try? diagnostics.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        try diagnostics.seek(toOffset: 0)
        let data = try diagnostics.read(upToCount: 4096) ?? Data()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ArchiveError.failure(message)
    }

    private enum ArchiveError: LocalizedError {
        case unsupported, invalidSelection, nameUnavailable, failure(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "此压缩格式暂不支持。"
            case .invalidSelection: return "请选择当前文件夹或其子目录中的项目。"
            case .nameUnavailable: return "无法为归档结果生成可用的名称。"
            case .failure(let message): return message.isEmpty ? "归档命令未能完成。" : message
            }
        }
    }
}
