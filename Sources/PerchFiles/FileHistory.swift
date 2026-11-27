import Foundation
import Observation

struct FileHistoryEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case copy = "复制", move = "移动", rename = "重命名", batchRename = "批量重命名", trash = "移到废纸篓"
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let count: Int
    let detail: String?
    var remaining: [FileRelocation]
    var restoredCount = 0
    var undoMessage: String?

    enum CodingKeys: String, CodingKey { case id, date, kind, count, detail, remaining, restoredCount, undoMessage }

    struct UndoResult: Sendable {
        var restored: [FileRelocation] = []
        var remaining: [FileRelocation] = []
        var failures: [FileOperationResult.Failure] = []

        mutating func fail(_ item: FileRelocation, _ error: Error) {
            remaining.append(item)
            failures.append(.init(source: item.original, message: error.localizedDescription))
        }
    }

    func undo() -> UndoResult {
        if kind == .batchRename || kind == .rename { return undoBatch() }
        var result = UndoResult()
        for item in remaining {
            do {
                try TransferFiles.restore(item)
                result.restored.append(item)
            } catch {
                result.fail(item, error)
            }
        }
        return result
    }

    private func undoBatch() -> UndoResult {
        var result = UndoResult()
        do {
            let current = remaining.compactMap(\.stamp)
            for item in remaining {
                guard let stamp = item.stamp, stamp == FileStamp(item.current) else {
                    throw TransferFileError.changedSource
                }
                if let occupant = FileStamp(item.original), !current.contains(where: { $0.sameObject(as: occupant) }) {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            try FileSystem.relocateGroup(remaining.map { ($0.current, $0.original) })
            result.restored = remaining
        } catch {
            for var item in remaining {
                let stamp = FileStamp(item.current)
                if item.stamp?.sameAfterRename(as: stamp) == true { item.stamp = stamp }
                result.fail(item, error)
            }
        }
        return result
    }
}

@MainActor @Observable
final class FileHistory {
    private let defaults: UserDefaults
    private let key = "wfolder.operations.v1"
    private(set) var entries: [FileHistoryEntry]
    var latestUndo: FileHistoryEntry? { entries.first { !$0.remaining.isEmpty } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([FileHistoryEntry].self, from: $0) } ?? []
    }

    @discardableResult
    func record(_ kind: FileHistoryEntry.Kind, count: Int, detail: String?, relocations: [FileRelocation]) -> UUID? {
        guard count > 0 else { return nil }
        let entry = FileHistoryEntry(date: Date(), kind: kind, count: count, detail: detail, remaining: relocations)
        entries.insert(entry, at: 0)
        if entries.count > 60 { entries.removeLast(entries.count - 60) }
        save()
        return entry.id
    }

    func didUndo(_ entry: FileHistoryEntry, result: FileHistoryEntry.UndoResult) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].remaining = result.remaining
        entries[index].restoredCount += result.restored.count
        entries[index].undoMessage = result.failures.isEmpty ? nil
            : FileOperationResult(failures: result.failures).failureSummary

        let restored = Dictionary(result.restored.map { (FileSystem.locationKey($0.original), FileStamp($0.original)) },
                                  uniquingKeysWith: { _, newest in newest })
        for older in entries.indices where older > index {
            for item in entries[older].remaining.indices {
                let previous = entries[older].remaining[item]
                if let stamp = restored[FileSystem.locationKey(previous.current)], previous.stamp?.sameAfterRename(as: stamp) == true {
                    entries[older].remaining[item].stamp = stamp
                }
            }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
