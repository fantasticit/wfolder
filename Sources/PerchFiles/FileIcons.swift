import AppKit
import UniformTypeIdentifiers

extension FileEntry {
    var isApplication: Bool {
        !isFolder && (contentType?.conforms(to: .application) == true
                      || url.pathExtension.caseInsensitiveCompare("app") == .orderedSame)
    }

    var hasNativeIcon: Bool { sourceLanguage == nil && mediaKind == nil && !isMarkdown }
}

@MainActor
final class FileIcons {
    static let shared = FileIcons()

    private let cache = NSCache<NSString, NSImage>()
    private let workers = OperationQueue()
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    private init() {
        cache.countLimit = 256
        workers.name = "wfolder.file-icons"
        workers.qualityOfService = .userInitiated
        workers.maxConcurrentOperationCount = 2
    }

    func load(for entry: FileEntry, completion: @escaping (NSImage) -> Void) {
        let path = entry.url.path
        let type: UTType? = entry.isFolder || entry.isApplication ? nil
            : entry.contentType ?? UTType(filenameExtension: entry.url.pathExtension) ?? .data
        let key = type.map { "type:\($0.identifier)" } ?? "path:\(path)\u{0}\(entry.modified?.timeIntervalSinceReferenceDate ?? -1)"
        if let image = cache.object(forKey: key as NSString) {
            completion(image)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        workers.addOperation { [weak self] in
            let image = type.map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(forFile: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cache.setObject(image, forKey: key as NSString)
                let completions = self.waiting.removeValue(forKey: key) ?? []
                for complete in completions { complete(image) }
            }
        }
    }
}
