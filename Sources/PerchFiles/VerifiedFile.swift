import CryptoKit
import Darwin
import Foundation

enum VerifiedFile {
    static let blockSize = 1024 * 1024

    static func open(_ url: URL, stamp: FileStamp, writable: Bool = false) throws -> FileHandle {
        guard stamp.regular, FileStamp(url) == stamp else { throw TransferFileError.changedSource }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { throw systemError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var actual = stat()
        guard fstat(fd, &actual) == 0, stamp.device == actual.st_dev, stamp.inode == actual.st_ino,
              actual.st_mode & S_IFMT == S_IFREG else { throw TransferFileError.changedSource }
        return handle
    }

    static func create(_ url: URL) throws -> FileHandle {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) } ?? -1
        }
        guard fd >= 0 else { throw systemError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func sha256(_ url: URL, stamp: FileStamp, copyingTo target: URL? = nil) throws -> String {
        let input = try open(url, stamp: stamp)
        defer { try? input.close() }
        let output = try target.map(create)
        defer { try? output?.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try input.read(upToCount: blockSize), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            try output?.write(contentsOf: data)
            count += Int64(data.count)
        }
        try output?.synchronize()
        guard count == stamp.bytes, FileStamp(url) == stamp else { throw TransferFileError.changedSource }
        return hex(hash.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func systemError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

struct ProfessionalStorage {
    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.perchfiles.browser",
            isDirectory: true).appendingPathComponent("Professional", isDirectory: true)
    }

    let directory: URL

    init(directory: URL = Self.directory) { self.directory = directory }

    func load<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value? {
        let location = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: location))
    }

    func save<Value: Encodable>(_ value: Value, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
