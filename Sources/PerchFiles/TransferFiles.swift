import Foundation

struct FileStamp: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let type: UInt16
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init?(_ url: URL) {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &info) }) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        type = info.st_mode & UInt16(S_IFMT)
        bytes = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
    }

    var regular: Bool { type == S_IFREG }
    var directory: Bool { type == S_IFDIR }
    var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1e9) }

    func sameObject(as other: Self?) -> Bool {
        guard let other else { return false }
        return device == other.device && inode == other.inode && type == other.type
    }

    func sameAfterRename(as other: Self?) -> Bool {
        guard let other else { return false }
        return sameObject(as: other) && bytes == other.bytes
            && modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos
    }
}

struct FileRelocation: Codable, Identifiable, Sendable {
    var id = UUID()
    let original: URL
    let current: URL
    var stamp: FileStamp?
    var wasInStash = false

    init(original: URL, current: URL) {
        self.original = original
        self.current = current
        stamp = FileStamp(current)
    }
}

enum TransferFileError: LocalizedError {
    case changedSource, changedFolder, changedTarget, unsupported, recovery([URL])

    var errorDescription: String? {
        switch self {
        case .changedSource: return "源项目已变更，请检查后重试。"
        case .changedFolder: return "目标文件夹已移动或替换。"
        case .changedTarget: return "同名项目已变更，请重新选择处理方式。"
        case .unsupported: return "无法传输此类文件。"
        case .recovery(let urls): return "有文件需要手动恢复。\n" + urls.map(\.path).joined(separator: "\n")
        }
    }
}

final class TransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    var bytes: Int64 { lock.withLock { value } }

    func update(_ bytes: Int64) {
        lock.withLock { value = bytes }
    }
}

enum TransferFiles {
    struct Destination: Sendable {
        let url: URL
        let physical: URL
        let stamp: FileStamp
        let caseSensitive: Bool

        init(_ url: URL) throws {
            self.url = url
            physical = FileSystem.physicalDirectory(url)
            guard let stamp = FileStamp(physical), stamp.directory else { throw TransferFileError.changedFolder }
            self.stamp = stamp
            let volume = try? physical.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            caseSensitive = volume?.volumeSupportsCaseSensitiveNames ?? false
        }

        func validate() throws {
            guard FileSystem.physicalDirectory(url).path == physical.path,
                  stamp.sameObject(as: FileStamp(physical)) else { throw TransferFileError.changedFolder }
        }

        func key(_ name: String) -> String {
            let value = name.precomposedStringWithCanonicalMapping
            return caseSensitive ? value : value.lowercased()
        }
    }

    struct Outcome: Sendable {
        let url: URL
        var replaced: FileRelocation?
        var warning: String?
    }

    private static let callback: copyfile_callback_t = { what, stage, state, _, _, context in
        if Task.isCancelled { return COPYFILE_QUIT }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let context {
            var bytes: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes) == 0 {
                Unmanaged<TransferMeter>.fromOpaque(context).takeUnretainedValue().update(bytes)
            }
        }
        return COPYFILE_CONTINUE
    }

    static func apply(_ source: URL, stamp: FileStamp, into destination: Destination,
                      name: String, operation: PaneTransferOperation, replacing expected: FileStamp? = nil,
                      meter: TransferMeter? = nil) throws -> Outcome {
        try Task.checkCancellation()
        try destination.validate()
        guard FileStamp(source) == stamp else { throw TransferFileError.changedSource }
        guard stamp.regular || stamp.directory || stamp.type == S_IFLNK else { throw TransferFileError.unsupported }

        let origin = FileSystem.physicalDirectory(source.deletingLastPathComponent())
        let physicalSource = origin.appendingPathComponent(source.lastPathComponent)
        let target = destination.physical.appendingPathComponent(name)
        let output = destination.url.appendingPathComponent(name, isDirectory: stamp.directory)
        let old = FileStamp(target)
        if expected == nil, operation == .move, origin.path == destination.physical.path,
           source.lastPathComponent.utf8.elementsEqual(name.utf8) { return Outcome(url: source) }
        if stamp.directory && (destination.physical.path == physicalSource.path
            || destination.physical.path.hasPrefix(physicalSource.path + "/")) { throw FileActionError.recursiveCopy }

        if let expected {
            guard expected == old, expected.regular, stamp.regular, !expected.sameObject(as: stamp) else {
                throw TransferFileError.changedTarget
            }
        } else if old != nil {
            throw CocoaError(.fileWriteFileExists)
        }
        let sameVolume = stamp.device == destination.stamp.device
        if operation == .move, sameVolume, expected == nil {
            do {
                try FileSystem.moveExclusive(from: physicalSource, to: target)
                guard stamp.sameAfterRename(as: FileStamp(target)) else {
                    if (try? FileSystem.moveExclusive(from: target, to: physicalSource)) != nil {
                        throw TransferFileError.changedSource
                    }
                    throw TransferFileError.recovery([target, physicalSource])
                }
                return Outcome(url: output)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [Int(EXDEV), Int(ENOTSUP)].contains(error.code) {
                // Fall through to a staged cross-volume move.
            }
        }

        let staging = try makeStaging(in: destination.physical)
        let payload = staging.appendingPathComponent(name)
        var sourceStaging: URL?
        var heldSource: URL?
        var preserveStaging = false
        var preserveSourceStaging = false
        defer {
            if !preserveStaging { try? FileManager.default.removeItem(at: staging) }
            if let sourceStaging, !preserveSourceStaging { try? FileManager.default.removeItem(at: sourceStaging) }
        }
        func discardHeldCopy() -> String? {
            guard let sourceStaging else { return nil }
            do {
                try FileManager.default.removeItem(at: sourceStaging)
                return nil
            } catch {
                preserveSourceStaging = true
                return "源卷上的临时文件未能清理，位置为 \(sourceStaging.path)"
            }
        }
        do {
            if operation == .move, sameVolume, expected != nil {
                try FileSystem.moveExclusive(from: physicalSource, to: payload)
                heldSource = payload
            } else {
                let snapshot = operation == .move && stamp.directory ? try treeStamp(physicalSource) : nil
                try copy(physicalSource, to: payload, stamp: stamp, meter: meter)
                guard FileStamp(physicalSource) == stamp else { throw TransferFileError.changedSource }
                try Task.checkCancellation()
                if operation == .move {
                    let hold = try makeStaging(in: origin)
                    sourceStaging = hold
                    let original = hold.appendingPathComponent(source.lastPathComponent)
                    try FileSystem.moveExclusive(from: physicalSource, to: original)
                    heldSource = original
                    if let snapshot, try treeStamp(original) != snapshot { throw TransferFileError.changedSource }
                }
            }
            if let heldSource, !stamp.sameAfterRename(as: FileStamp(heldSource)) {
                throw TransferFileError.changedSource
            }
            try Task.checkCancellation()
            try destination.validate()
            guard let expected else {
                try FileSystem.moveExclusive(from: payload, to: target)
                return Outcome(url: output, warning: discardHeldCopy())
            }
            guard expected == FileStamp(target) else { throw TransferFileError.changedTarget }
            let incoming = FileStamp(payload)
            try swap(payload, target)
            guard expected.sameAfterRename(as: FileStamp(payload)), incoming?.sameAfterRename(as: FileStamp(target)) == true else {
                if incoming?.sameAfterRename(as: FileStamp(target)) == true, (try? swap(payload, target)) != nil {
                    throw TransferFileError.changedTarget
                }
                preserveStaging = true
                preserveSourceStaging = true
                throw TransferFileError.recovery([payload, target] + (sourceStaging.map { [$0] } ?? []))
            }
            var backup: URL?
            var warning: String?
            do {
                backup = try FileSystem.trash(payload)
                if backup == nil { warning = "旧文件已移入废纸篓，系统未返回其位置。" }
            } catch {
                warning = "旧文件保留在 \(payload.path)"
                backup = payload
                preserveStaging = true
            }
            let warnings = [warning, discardHeldCopy()].compactMap { $0 }
            return Outcome(url: output, replaced: backup.map { FileRelocation(original: output, current: $0) },
                           warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
        } catch {
            if let heldSource, !preserveStaging,
               (try? FileSystem.moveExclusive(from: heldSource, to: physicalSource)) == nil {
                preserveStaging = true
                preserveSourceStaging = true
                throw TransferFileError.recovery([heldSource, physicalSource])
            }
            throw error
        }
    }

    static func restore(_ item: FileRelocation) throws {
        guard let stamp = item.stamp, stamp == FileStamp(item.current) else { throw TransferFileError.changedSource }
        let directory = try Destination(item.original.deletingLastPathComponent())
        _ = try apply(item.current, stamp: stamp, into: directory, name: item.original.lastPathComponent, operation: .move)
    }

    private static func copy(_ source: URL, to target: URL, stamp: FileStamp, meter: TransferMeter?) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let handler = unsafeBitCast(callback, to: UnsafeRawPointer.self)
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), handler) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if let meter {
            let context = Unmanaged.passUnretained(meter).toOpaque()
            guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_DATA_SPARSE)
        if stamp.directory { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        let result = source.withUnsafeFileSystemRepresentation { a in
            target.withUnsafeFileSystemRepresentation { b in copyfile(a, b, state, flags) }
        }
        let code = errno
        try Task.checkCancellation()
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }

    private static func treeStamp(_ root: URL) throws -> [String: FileStamp] {
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [],
                errorHandler: { _, error in failure = error; return false }) else {
            throw TransferFileError.changedSource
        }
        var stamps: [String: FileStamp] = [:]
        for case let file as URL in iterator {
            try Task.checkCancellation()
            guard let stamp = FileStamp(file) else { throw TransferFileError.changedSource }
            stamps[String(file.path.dropFirst(root.path.count))] = stamp
        }
        if let failure { throw failure }
        return stamps
    }

    private static func makeStaging(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(".wfolder-transfer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func swap(_ source: URL, _ target: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { a in
            target.withUnsafeFileSystemRepresentation { b in
                renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
