import AppKit

enum PaneTransferOperation: Sendable {
    case copy, move

    var title: String { self == .move ? "移动" : "复制" }
    var dragOperation: NSDragOperation { self == .move ? .move : .copy }

    static func drag(sameVolume: Bool, modifiers: NSEvent.ModifierFlags, allowed: NSDragOperation) -> Self? {
        if modifiers.contains(.option) { return allowed.contains(.copy) ? .copy : nil }
        if (sameVolume || modifiers.contains(.command)), allowed.contains(.move) { return .move }
        return allowed.contains(.copy) ? .copy : nil
    }
}

struct PaneTransfer: Sendable {
    let sources: [URL]
    let directory: URL
    let operation: PaneTransferOperation
    var fromStash = false
}

enum FileDropHint: Equatable {
    case stash
    case transfer(URL, PaneTransferOperation)

    var directory: URL? {
        if case .transfer(let directory, _) = self { return directory }
        return nil
    }

    var title: String {
        switch self {
        case .stash: return "加入暂存架"
        case .transfer(let directory, let operation):
            return "\(operation.title)到「\(directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent)」"
        }
    }
}

@MainActor protocol FileDragSource: AnyObject {
    var dragsFromStash: Bool { get }
}

@MainActor
final class FileDropScrollView: OverlayScrollView {
    var canReceive: () -> Bool = { false }
    var destination: (NSPoint) -> URL? = { _ in nil }
    var showHint: (FileDropHint?) -> Void = { _ in }
    var receive: ([URL], URL, PaneTransferOperation, Bool) -> Bool = { _, _, _, _ in false }
    var storeInStash: (([URL]) -> Void)?

    private var sources: [URL] = []
    private var volumes: [NSObject] = []
    private var fromStash = false
    private var knowsSourceVolumes = false
    private var lastDirectory: URL?
    private var lastSharesVolume = false
    private var isRecursive = false
    private var canMoveIntoDirectory = false
    private var hint: FileDropHint?

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        sources = urls.filter(\.isFileURL)
        fromStash = (info.draggingSource as? any FileDragSource)?.dragsFromStash == true
        let parentDirectories = Set(sources.map { $0.deletingLastPathComponent() })
        volumes = parentDirectories.compactMap(Self.volume)
        knowsSourceVolumes = volumes.count == parentDirectories.count
        lastDirectory = nil
        return updateDrop(info)
    }

    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        if !sources.isEmpty, storeInStash != nil || canReceive() { scrollNearEdge(info.draggingLocation) }
        return updateDrop(info)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearDrop() }

    override func draggingEnded(_ sender: any NSDraggingInfo) { clearDrop() }

    override func prepareForDragOperation(_ info: any NSDraggingInfo) -> Bool { updateDrop(info) != [] }

    override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
        defer { clearDrop() }
        guard updateDrop(info) != [], let hint else { return false }
        switch hint {
        case .stash:
            guard let storeInStash else { return false }
            storeInStash(sources)
            return true
        case .transfer(let directory, let operation):
            return receive(sources, directory, operation, fromStash)
        }
    }

    private func updateDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard !sources.isEmpty, contentView.frame.contains(convert(info.draggingLocation, from: nil)) else {
            updateHint(nil)
            return []
        }
        if storeInStash != nil {
            let accepts = !fromStash && info.draggingSourceOperationMask.contains(.copy)
            updateHint(accepts ? .stash : nil)
            return accepts ? .copy : []
        }
        guard canReceive(), let directory = destination(info.draggingLocation) else {
            updateHint(nil)
            return []
        }
        if directory != lastDirectory {
            lastDirectory = directory
            let targetVolume = Self.volume(directory)
            lastSharesVolume = knowsSourceVolumes && targetVolume != nil && volumes.allSatisfy { $0 == targetVolume }
            let path = directory.path
            isRecursive = sources.contains { path == $0.path || path.hasPrefix($0.path + "/") }
            canMoveIntoDirectory = sources.contains { $0.deletingLastPathComponent().path != path }
        }
        guard let operation = PaneTransferOperation.drag(sameVolume: !fromStash && lastSharesVolume,
                  modifiers: NSEvent.modifierFlags, allowed: info.draggingSourceOperationMask),
              !isRecursive, operation == .copy || canMoveIntoDirectory else {
            updateHint(nil)
            return []
        }
        updateHint(.transfer(directory, operation))
        return operation.dragOperation
    }

    private static func volume(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private func scrollNearEdge(_ location: NSPoint) {
        let clip = contentView
        let point = clip.convert(location, from: nil)
        let bounds = clip.bounds
        guard bounds.contains(point) else { return }
        let edge = min(20, bounds.height / 3)
        let step: CGFloat = point.y < bounds.minY + edge ? -12 : point.y > bounds.maxY - edge ? 12 : 0
        guard step != 0 else { return }
        let next = clip.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: step)).origin
        if next != bounds.origin {
            clip.scroll(to: next)
            reflectScrolledClipView(clip)
        }
    }

    private func updateHint(_ next: FileDropHint?) {
        guard next != hint else { return }
        hint = next
        showHint(next)
    }

    private func clearDrop() {
        updateHint(nil)
        sources.removeAll()
        volumes.removeAll()
        lastDirectory = nil
    }
}
