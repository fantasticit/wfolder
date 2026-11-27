import SwiftUI
import UniformTypeIdentifiers

/// Sidebar destinations use the same transfer queue and modifier rules as file panes.
struct DirectoryDrop: ViewModifier {
    let directory: URL
    let workspace: BrowserWorkspace
    @ViewState private var hint: String?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(hint == nil ? Color.clear : Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 5))
            .overlay {
                if hint != nil {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .help(hint ?? directory.path)
            .onDrop(of: [.fileURL], delegate: Destination(directory: directory, workspace: workspace, hint: $hint))
    }

    @MainActor private struct Destination: DropDelegate {
        let directory: URL
        let workspace: BrowserWorkspace
        @Binding var hint: String?

        private var sources: [URL] {
            NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        private func operation() -> PaneTransferOperation? {
            DirectoryDrop.operation(sources: sources, directory: directory,
                                    modifiers: NSEvent.modifierFlags,
                                    fromStash: workspace.activeBrowser.isStash)
        }

        func validateDrop(info: DropInfo) -> Bool { operation() != nil }

        func dropEntered(info: DropInfo) { updateHint() }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            updateHint()
            guard let operation = operation() else { return DropProposal(operation: .forbidden) }
            return DropProposal(operation: operation == .move ? .move : .copy)
        }

        func dropExited(info: DropInfo) { hint = nil }

        func performDrop(info: DropInfo) -> Bool {
            defer { hint = nil }
            guard let operation = operation() else { return false }
            return workspace.transfer(sources, into: directory, operation: operation,
                                      fromStash: workspace.activeBrowser.isStash, reportsDropResult: true)
        }

        private func updateHint() {
            hint = operation().map { FileDropHint.transfer(directory, $0).title }
        }
    }

    static func operation(sources: [URL], directory: URL, modifiers: NSEvent.ModifierFlags,
                          fromStash: Bool = false) -> PaneTransferOperation? {
        guard directory.isFileURL, !sources.isEmpty, sources.allSatisfy(\.isFileURL) else { return nil }
        let target = FileSystem.physicalDirectory(directory)
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .volumeIdentifierKey])
        guard values?.isDirectory == true else { return nil }
        let targetVolume = values?.volumeIdentifier as? NSObject
        var sameVolume = targetVolume != nil
        for source in sources {
            let physical = FileSystem.physicalDirectory(source)
            guard target.path != physical.path, !target.path.hasPrefix(physical.path + "/") else { return nil }
            let volume = (try? physical.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            sameVolume = sameVolume && volume != nil && volume == targetVolume
        }
        guard let operation = PaneTransferOperation.drag(sameVolume: sameVolume && !fromStash,
                    modifiers: modifiers, allowed: [.copy, .move]),
              operation == .copy || sources.contains(where: {
                  FileSystem.physicalDirectory($0.deletingLastPathComponent()).path != target.path
              }) else { return nil }
        return operation
    }
}
