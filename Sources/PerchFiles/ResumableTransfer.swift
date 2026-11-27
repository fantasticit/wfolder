import CryptoKit
import Foundation
import Observation

struct ResumableTransfer: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case waiting = "待传输", running = "复制中", paused = "可继续", completed = "已校验"
    }

    var id = UUID()
    let source: URL
    let original: FileStamp
    let destination: URL
    let originalFolder: FileStamp
    let targetName: String
    var status = Status.waiting
    var digest: String?
    var message: String?

    var target: URL { destination.appendingPathComponent(targetName) }
    private var staging: URL { destination.appendingPathComponent(".wfolder-transfer-" + id.uuidString, isDirectory: true) }
    private var marker: URL { staging.appendingPathComponent("id") }
    private var payload: URL { staging.appendingPathComponent("partial") }

    init(source: URL, destination: TransferFiles.Destination, occupied: inout Set<String>) throws {
        guard let stamp = FileStamp(source), stamp.regular else { throw TransferFileError.unsupported }
        self.source = source
        original = stamp
        self.destination = destination.physical
        originalFolder = destination.stamp
        let ext = source.pathExtension
        let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let suffix = ext.isEmpty ? "" : "." + ext
        guard let name = (1...10_000).lazy.map({ number in
            number == 1 ? source.lastPathComponent : stem + " 副本 \(number)" + suffix
        }).first(where: { !occupied.contains(destination.key($0)) }) else { throw FileActionError.duplicateLimit }
        targetName = name
        occupied.insert(destination.key(name))
    }

    func copy(meter: TransferMeter, checkpoint: @MainActor (String) throws -> Void) async throws -> String {
        let fm = FileManager.default
        try Task.checkCancellation()
        let folder = try TransferFiles.Destination(destination)
        guard folder.physical.path == destination.path else { throw TransferFileError.changedFolder }
        let stagingExists = FileStamp(staging)?.directory == true
        if stagingExists {
            try checkMarker()
        } else {
            guard originalFolder.sameObject(as: folder.stamp) else { throw TransferFileError.changedFolder }
        }
        if let existing = FileStamp(target) {
            guard let digest, existing.regular, existing.bytes == original.bytes,
                  try VerifiedFile.sha256(target, stamp: existing) == digest else { throw TransferFileError.changedTarget }
            if stagingExists { try? fm.removeItem(at: staging) }
            return digest
        }
        guard FileStamp(source) == original else { throw TransferFileError.changedSource }
        if !stagingExists {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let identity = try VerifiedFile.create(marker)
            defer { try? identity.close() }
            try identity.write(contentsOf: Data(id.uuidString.utf8))
            try identity.synchronize()
        }
        if FileStamp(payload) == nil {
            try VerifiedFile.create(payload).close()
        }
        guard let partial = FileStamp(payload), partial.regular, partial.bytes <= original.bytes else {
            throw ResumeError.invalidPartial
        }
        var hash = SHA256()
        let input = try VerifiedFile.open(source, stamp: original)
        defer { try? input.close() }
        let output = try VerifiedFile.open(payload, stamp: partial, writable: true)
        defer { try? output.close() }
        var offset: Int64 = 0
        while offset < partial.bytes {
            try Task.checkCancellation()
            let size = Int(min(Int64(VerifiedFile.blockSize), partial.bytes - offset))
            guard let previous = try output.read(upToCount: size), previous.count == size,
                  let same = try input.read(upToCount: size), same == previous else { throw ResumeError.invalidPartial }
            hash.update(data: previous)
            offset += Int64(previous.count)
            meter.update(offset)
        }
        while let buffer = try input.read(upToCount: VerifiedFile.blockSize), !buffer.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: buffer)
            hash.update(data: buffer)
            offset += Int64(buffer.count)
            meter.update(offset)
        }
        try output.synchronize()
        guard offset == original.bytes, FileStamp(source) == original,
              let written = FileStamp(payload), written.sameObject(as: partial) else { throw TransferFileError.changedSource }
        let digest = VerifiedFile.hex(hash.finalize())
        guard try VerifiedFile.sha256(payload, stamp: written) == digest else { throw ResumeError.invalidPartial }
        try await checkpoint(digest)
        try Task.checkCancellation()
        try folder.validate()
        try checkMarker()
        guard FileStamp(payload) == written else { throw ResumeError.invalidPartial }
        do { try FileSystem.moveExclusive(from: payload, to: target) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && [Int(ENOTSUP), Int(ENOSYS)].contains(error.code) {
            try TransferFiles.publish(payload, to: target)
        }
        guard let finished = FileStamp(target), finished.bytes == original.bytes,
              try (finished.sameAfterRename(as: written) || VerifiedFile.sha256(target, stamp: finished) == digest) else {
            throw ResumeError.invalidPartial
        }
        try? fm.setAttributes([.modificationDate: original.modified], ofItemAtPath: target.path)
        try? fm.removeItem(at: staging)
        return digest
    }

    func discardPartial() throws {
        guard FileStamp(staging) != nil else {
            _ = try TransferFiles.Destination(destination)
            return
        }
        try checkMarker()
        try FileManager.default.removeItem(at: staging)
    }

    private func checkMarker() throws {
        guard FileStamp(staging)?.directory == true, let stamp = FileStamp(marker),
              stamp.regular, stamp.bytes == 36 else { throw ResumeError.invalidPartial }
        let input = try VerifiedFile.open(marker, stamp: stamp)
        defer { try? input.close() }
        guard let bytes = try input.read(upToCount: 36), String(decoding: bytes, as: UTF8.self) == id.uuidString else {
            throw ResumeError.invalidPartial
        }
    }

    private enum ResumeError: LocalizedError {
        case invalidPartial
        var errorDescription: String? { "临时数据或目标内容与原文件不一致。可移除任务后重新复制。" }
    }
}

@MainActor @Observable
final class ResumableTransfers {
    private let storage: ProfessionalStorage
    private(set) var jobs: [ResumableTransfer]
    private(set) var issue: String?
    private(set) var active: UUID?
    let meter = TransferMeter()
    @ObservationIgnored private var worker: Task<String, Error>?

    init(storage: ProfessionalStorage) {
        self.storage = storage
        do {
            jobs = (try storage.load([ResumableTransfer].self, "resumable.json") ?? []).map { old in
                var job = old
                if job.status == .running { job.status = .paused }
                return job
            }
        } catch { jobs = []; issue = "无法读取可恢复传输的记录。" }
    }

    @discardableResult
    func enqueue(_ urls: [URL], to directory: URL) async -> Bool {
        let queued = jobs.filter { $0.destination.path == directory.standardizedFileURL.path && $0.status != .completed }
        do {
            let drafts = try await Task.detached(priority: .userInitiated) {
                let target = try TransferFiles.Destination(directory)
                let names = try FileManager.default.contentsOfDirectory(atPath: target.physical.path)
                var occupied = Set((names + queued.map(\.targetName)).map(target.key))
                return try FileSystem.selectedRoots(urls).map { try ResumableTransfer(source: $0, destination: target, occupied: &occupied) }
            }.value
            try persist(jobs + drafts)
            startNext()
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }

    func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.status == .paused }) else { return }
        var next = jobs
        next[index].status = .waiting
        next[index].message = nil
        do { try persist(next); startNext() }
        catch { issue = error.localizedDescription }
    }

    func pause() { worker?.cancel() }
    func startWaiting() { startNext() }

    func remove(_ job: ResumableTransfer) async {
        guard job.id != active, jobs.contains(where: { $0.id == job.id && $0.status != .waiting }) else { return }
        do {
            if job.status != .completed {
                try await Task.detached { try job.discardPartial() }.value
            }
            try persist(jobs.filter { $0.id != job.id })
        } catch { issue = error.localizedDescription }
    }

    private func startNext() {
        guard active == nil, let index = jobs.firstIndex(where: { $0.status == .waiting }) else { return }
        var next = jobs
        next[index].status = .running
        do { try persist(next) } catch { issue = error.localizedDescription; return }
        let job = next[index]
        active = job.id
        meter.update(0)
        let meter = meter
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try await job.copy(meter: meter) { [weak self] digest in
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }) else {
                    throw CancellationError()
                }
                var values = self.jobs
                values[index].digest = digest
                try self.persist(values)
            }
        }
        self.worker = worker
        Task {
            let result = await worker.result
            self.worker = nil
            active = nil
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
            var final = jobs
            switch result {
            case .success(let digest):
                final[index].status = .completed
                final[index].digest = digest
            case .failure(let error):
                final[index].status = .paused
                let message = error is CancellationError ? "已暂停，保留已复制的数据。" : error.localizedDescription
                final[index].message = message
            }
            do { try persist(final) }
            catch { jobs = final; issue = error.localizedDescription }
            if !worker.isCancelled { startNext() }
        }
    }

    private func persist(_ value: [ResumableTransfer]) throws {
        try storage.save(value, "resumable.json")
        jobs = value
        issue = nil
    }
}
