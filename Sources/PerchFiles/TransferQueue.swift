import Foundation
import Observation

enum ConflictDecision: String, CaseIterable, Identifiable, Sendable {
    case skip = "跳过", keepBoth = "保留两份", replace = "替换"
    var id: Self { self }
}

struct TransferItem: Sendable {
    let url: URL
    let stamp: FileStamp
    var name: String { url.lastPathComponent }
}

struct TransferConflict: Identifiable, Sendable {
    let item: TransferItem
    let occupant: URL
    let stamp: FileStamp
    let canReplace: Bool
    var id: URL { item.url }
}

private struct TransferPreparation: Sendable {
    let destination: TransferFiles.Destination
    var items: [TransferItem] = []
    var conflicts: [TransferConflict] = []
    var failures: [FileOperationResult.Failure] = []

    init(_ request: PaneTransfer) throws {
        destination = try TransferFiles.Destination(request.directory)
        var incoming: [String: TransferItem] = [:]
        for url in request.sources {
            try Task.checkCancellation()
            guard let stamp = FileStamp(url) else {
                failures.append(.init(source: url, message: "源项目不存在或无法读取。"))
                continue
            }
            let item = TransferItem(url: url, stamp: stamp)
            let target = destination.physical.appendingPathComponent(item.name)
            let logicalTarget = destination.url.appendingPathComponent(item.name)
            let key = destination.key(item.name)
            if request.operation == .move,
               FileSystem.physicalDirectory(url.deletingLastPathComponent()).path == destination.physical.path {
                items.append(item)
            } else if let existing = FileStamp(target) {
                conflicts.append(.init(item: item, occupant: logicalTarget, stamp: existing,
                                       canReplace: destination.supportsSwap && incoming[key] == nil && item.stamp.regular && existing.regular && !existing.sameObject(as: stamp)))
            } else if let earlier = incoming[key] {
                conflicts.append(.init(item: item, occupant: earlier.url, stamp: earlier.stamp, canReplace: false))
            } else {
                items.append(item)
            }
            incoming[key] = item
        }
    }
}

@MainActor @Observable
final class TransferJob: Identifiable {
    enum State: String {
        case queued = "排队中", scanning = "检查源文件和目标", running = "传输中"
        case conflicts = "等待处理同名项目", complete = "已完成", partial = "有项目失败"
        case cancelled = "已取消"

        var finished: Bool { self == .complete || self == .partial || self == .cancelled }
    }

    let id = UUID()
    let request: PaneTransfer
    var state: State = .queued
    var current: TransferItem?
    var meter: TransferMeter?
    var conflicts: [TransferConflict] = []
    var reviewID = UUID()
    var draftDecisions: [URL: ConflictDecision] = [:]
    var failures: [FileOperationResult.Failure] = []
    var warnings: [String] = []
    var completed: Set<URL> = []
    var skipped = 0
    var moved: [FileRelocation] = []
    var backups: [FileRelocation] = []
    var cancelling = false
    @ObservationIgnored let onFinish: ((TransferJob) -> Void)?

    init(_ request: PaneTransfer, onFinish: ((TransferJob) -> Void)?) {
        self.request = request
        self.onFinish = onFinish
    }

    var total: Int { request.sources.count }
    var processed: Int { completed.count + skipped + failures.count }
    var sourceSummary: String {
        if request.fromStash { return "文件暂存架" }
        let first = request.sources[0].deletingLastPathComponent()
        return request.sources.allSatisfy { $0.deletingLastPathComponent().path == first.path }
            ? first.path : "多个来源目录"
    }
}

@MainActor @Observable
final class TransferQueue {
    private(set) var jobs: [TransferJob] = []
    private(set) var active: TransferJob?
    @ObservationIgnored private var cancelWorker: (() -> Void)?
    @ObservationIgnored private var review: CheckedContinuation<[URL: ConflictDecision], Never>?

    var hasWaiting: Bool { jobs.contains { $0.state == .queued } }
    var unfinished: Int { jobs.count { !$0.state.finished } }
    var conflictJob: TransferJob? { active?.state == .conflicts ? active : nil }

    func append(_ request: PaneTransfer, onFinish: ((TransferJob) -> Void)? = nil) {
        jobs.append(TransferJob(request, onFinish: onFinish))
        prune()
    }

    func startNext(onFinish: @escaping (TransferJob) -> Void) {
        guard active == nil, let job = jobs.first(where: { $0.state == .queued }) else { return }
        active = job
        job.state = .scanning
        Task {
            await run(job)
            job.meter = nil
            job.current = nil
            job.state = job.cancelling ? .cancelled : job.failures.isEmpty ? .complete : .partial
            active = nil
            job.onFinish?(job)
            onFinish(job)
            prune()
        }
    }

    func cancel(_ job: TransferJob) {
        guard !job.state.finished, !job.cancelling else { return }
        if active === job {
            job.cancelling = true
            cancelWorker?()
            review?.resume(returning: [:])
            review = nil
        } else {
            job.state = .cancelled
            job.onFinish?(job)
            prune()
        }
    }

    func resolve(_ job: TransferJob, decisions: [URL: ConflictDecision]) {
        guard conflictJob === job, let review else { return }
        self.review = nil
        review.resume(returning: decisions)
    }

    private func run(_ job: TransferJob) async {
        guard !job.cancelling else { return }
        let request = job.request
        let preparation: TransferPreparation
        do {
            preparation = try await background { try TransferPreparation(request) }
        } catch is CancellationError {
            return
        } catch {
            job.failures = request.sources.map { .init(source: $0, message: error.localizedDescription) }
            return
        }
        job.failures = preparation.failures
        let destination = preparation.destination
        var pending = preparation.conflicts
        var written = Set<String>()
        job.state = .running
        for item in preparation.items {
            guard !job.cancelling else { return }
            if let conflict = await apply(item, decision: .keepBoth, reviewed: nil, job: job,
                                          destination: destination, written: &written) { pending.append(conflict) }
        }
        while !pending.isEmpty, !job.cancelling {
            job.current = nil
            job.meter = nil
            job.reviewID = UUID()
            job.conflicts = pending
            job.draftDecisions = [:]
            job.state = .conflicts
            let decisions = await withCheckedContinuation { review = $0 }
            job.conflicts = []
            job.state = .running
            let previous = pending
            pending.removeAll()
            for conflict in previous {
                guard !job.cancelling else { return }
                let choice = decisions[conflict.id] ?? .skip
                if choice == .skip {
                    job.skipped += 1
                } else if let changed = await apply(conflict.item,
                    decision: choice == .replace && !conflict.canReplace ? .keepBoth : choice,
                    reviewed: conflict, job: job, destination: destination, written: &written) {
                    pending.append(changed)
                }
            }
        }
    }

    private func apply(_ item: TransferItem, decision: ConflictDecision, reviewed: TransferConflict?,
                       job: TransferJob, destination: TransferFiles.Destination,
                       written: inout Set<String>) async -> TransferConflict? {
        let meter = TransferMeter()
        let operation = job.request.operation
        job.current = item
        job.meter = meter
        do {
            let outcome = try await background {
                try Self.write(item, destination: destination, operation: operation,
                               decision: reviewed == nil ? nil : decision, reviewed: reviewed, meter: meter)
            }
            job.completed.insert(item.url)
            written.insert(destination.key(outcome.url.lastPathComponent))
            if let warning = outcome.warning { job.warnings.append(warning) }
            if operation == .move, outcome.url.path != item.url.path {
                if !outcome.sourceRetained { job.moved.append(FileRelocation(original: item.url, current: outcome.url)) }
                if let backup = outcome.replaced { job.backups.append(backup) }
            }
        } catch is CancellationError {
            return nil
        } catch where FileSystem.isNameConflict(error) || (error as? TransferFileError)?.isChangedTarget == true {
            let target = destination.physical.appendingPathComponent(item.name)
            if let stamp = FileStamp(target) {
                return TransferConflict(item: item, occupant: destination.url.appendingPathComponent(item.name), stamp: stamp,
                    canReplace: item.stamp.regular && stamp.regular && !stamp.sameObject(as: item.stamp)
                        && !written.contains(destination.key(item.name)))
            }
            job.failures.append(.init(source: item.url, message: error.localizedDescription))
        } catch {
            job.failures.append(.init(source: item.url, message: error.localizedDescription))
        }
        return nil
    }

    private nonisolated static func write(_ item: TransferItem, destination: TransferFiles.Destination,
                                           operation: PaneTransferOperation, decision: ConflictDecision?,
                                           reviewed: TransferConflict?, meter: TransferMeter) throws -> TransferFiles.Outcome {
        let current = FileStamp(destination.physical.appendingPathComponent(item.name))
        if decision == .replace, let reviewed, current != nil {
            return try TransferFiles.apply(item.url, stamp: item.stamp, into: destination, name: item.name,
                                           operation: operation, replacing: reviewed.stamp, meter: meter)
        }
        if decision == .keepBoth, current != nil {
            let ext = item.stamp.directory ? "" : item.url.pathExtension
            let stem = ext.isEmpty ? item.name : item.url.deletingPathExtension().lastPathComponent
            for index in 1...10_000 {
                let suffix = index == 1 ? " 副本" : " 副本 \(index)"
                let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
                do {
                    return try TransferFiles.apply(item.url, stamp: item.stamp, into: destination,
                                                   name: name, operation: operation, meter: meter)
                } catch where FileSystem.isNameConflict(error) { continue }
            }
            throw FileActionError.duplicateLimit
        }
        return try TransferFiles.apply(item.url, stamp: item.stamp, into: destination, name: item.name,
                                       operation: operation, meter: meter)
    }

    private func background<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        cancelWorker = { worker.cancel() }
        defer { cancelWorker = nil }
        return try await worker.value
    }

    private func prune() {
        var count = jobs.count { $0.state.finished }
        jobs.removeAll { job in
            guard job.state.finished, count > 30 else { return false }
            count -= 1
            return true
        }
    }
}

private extension TransferFileError {
    var isChangedTarget: Bool { if case .changedTarget = self { return true }; return false }
}
