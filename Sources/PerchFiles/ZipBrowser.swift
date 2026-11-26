import AppKit
import CArchive
import SwiftUI
import UniformTypeIdentifiers

struct ZipContents: Sendable {
    struct Member: Identifiable, Sendable {
        let path: String
        let isDirectory: Bool
        let size: Int64?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var parent: String { (path as NSString).deletingLastPathComponent }
    }

    let children: [String: [Member]]
    let skipped: Int

    static func supports(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".zip", ".tar", ".tgz", ".tbz", ".tbz2", ".txz", ".tzst", ".7z", ".rar",
                ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma"].contains { name.hasSuffix($0) }
    }

    init(archive: URL) throws {
        var members: [String: Member] = [:]
        var skipped = 0
        try Self.read(archive) { _, member in
            guard let member else { skipped += 1; return }
            if let existing = members[member.path], !existing.isDirectory || !member.isDirectory { skipped += 1 }
            else { members[member.path] = member }
            var parent = member.parent
            while !parent.isEmpty, members[parent] == nil {
                members[parent] = Member(path: parent, isDirectory: true, size: nil)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        children = Dictionary(grouping: members.values, by: \.parent).mapValues { rows in
            rows.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        self.skipped = skipped
    }

    static func extract(_ entries: Set<String>, in folder: String, archive: FileEntry, into destination: URL) throws -> [URL] {
        let current = FileEntry.read(archive.url)
        guard archive.modified == current.modified, archive.size == current.size else { throw ZipError.changed }
        let prefix = folder.isEmpty ? "" : folder + "/"
        let selected = Set(entries.filter { $0.hasPrefix(prefix) && !(String($0.dropFirst(prefix.count)).contains("/")) })
        guard !selected.isEmpty else { return [] }
        let fm = FileManager.default
        let location = try TransferFiles.Destination(destination)
        let parent = location.isNetwork ? fm.temporaryDirectory : destination
        let staging = parent.appendingPathComponent(".wfolder-zip-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var extracted = Set<String>()
        try read(archive.url) { reader, member in
            guard let member, member.path.hasPrefix(prefix) else { return }
            let relative = String(member.path.dropFirst(prefix.count))
            guard let first = relative.split(separator: "/").first,
                  selected.contains(prefix + String(first)) else { return }
            let target = staging.appendingPathComponent(relative, isDirectory: member.isDirectory)
            if member.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writeMember(reader, to: target)
            }
            extracted.insert(prefix + String(first))
        }
        guard selected == extracted else { throw ZipError.changed }

        var published: [(original: URL, output: URL)] = []
        do {
            for path in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey]) {
                let folder = try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
                let ext = folder || path.pathExtension.isEmpty ? "" : "." + path.pathExtension
                let name = ext.isEmpty ? path.lastPathComponent : path.deletingPathExtension().lastPathComponent
                let output = try FileArchive.publish(path, in: destination, name: name, extension: ext)
                published.append((path, output))
            }
        } catch {
            let failed = published.filter { (try? TransferFiles.publish($0.output, to: $0.original)) == nil }
            if !failed.isEmpty { throw ZipError.partial(failed.map { $0.output.path }) }
            throw error
        }
        return published.map(\.output)
    }

    static func copyParts(_ paths: [String: URL], from archive: URL, maxPartBytes: Int64? = nil) throws {
        var remaining = paths
        try read(archive) { reader, member in
            guard let member, !member.isDirectory, let target = remaining.removeValue(forKey: member.path) else { return }
            if let maxPartBytes, member.size.map({ $0 >= 0 && $0 <= maxPartBytes }) != true {
                throw ZipError.couldNotRead("工作簿的压缩内容超出预览大小限制。")
            }
            try writeMember(reader, to: target)
        }
        if !remaining.isEmpty { throw ZipError.couldNotRead("归档缺少所需的文件。") }
    }

    private static func writeMember(_ reader: OpaquePointer, to target: URL) throws {
        let fd = target.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard archive_read_data_into_fd(reader, fd) == 0 else { throw error(reader) }
    }

    private static func read(_ url: URL, each: (OpaquePointer, Member?) throws -> Void) throws {
        guard let archive = archive_read_new() else { throw ZipError.couldNotRead("无法初始化归档读取器。") }
        defer { archive_read_free(archive) }
        let zip = ["zip", "xlsx"].contains(url.pathExtension.lowercased())
        if zip {
            guard archive_read_support_format_zip_seekable(archive) == 0 else { throw error(archive) }
        } else {
            guard archive_read_support_format_all(archive) >= -20,
                  archive_read_support_filter_all(archive) >= -20 else { throw error(archive) }
        }
        guard
              url.withUnsafeFileSystemRepresentation({ archive_read_open_filename(archive, $0, 64 * 1024) }) == 0
        else { throw error(archive) }
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(archive, &entry)
            if status == 1 { break }
            guard (status == 0 || status == -20), let entry else { throw error(archive) }
            try each(archive, member(entry))
        }
    }

    private static func member(_ entry: OpaquePointer) -> Member? {
        let mode = UInt32(archive_entry_filetype(entry))
        let isDirectory = mode == S_IFDIR
        guard isDirectory || (mode == S_IFREG && archive_entry_hardlink(entry) == nil),
              let pointer = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
              let raw = String(validatingUTF8: pointer), !raw.hasPrefix("/"), !raw.contains("\\") else { return nil }
        let components = raw.split(separator: "/").drop(while: { $0 == "." })
        guard !components.isEmpty, components.allSatisfy({
            $0 != ".." && $0 != "." && !$0.contains(":")
        }) else { return nil }
        return Member(path: components.joined(separator: "/"), isDirectory: isDirectory,
                      size: isDirectory ? nil : archive_entry_size(entry))
    }

    private static func error(_ archive: OpaquePointer) -> ZipError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "无法读取归档。"
        return .couldNotRead(message)
    }
}

private enum ZipError: LocalizedError {
    case changed, couldNotRead(String), partial([String])
    var errorDescription: String? {
        switch self {
        case .changed: return "归档内容已变化，请重新打开。"
        case .couldNotRead(let message): return message
        case .partial(let paths): return "部分文件已解压到以下位置。\n" + paths.joined(separator: "\n")
        }
    }
}

struct ZipBrowserView: View {
    let archive: FileEntry
    let browser: BrowserModel
    let close: () -> Void
    @ViewState private var contents: ZipContents?
    @ViewState private var folder = ""
    @ViewState private var selection: Set<String> = []
    @ViewState private var message: String?
    @ViewState private var readError: String?
    @ViewState private var previewCache = ArchivePreviewCache()

    private var previewPath: String? {
        guard selection.count == 1, let item = entries.first(where: { selection.contains($0.id) }),
              !item.isDirectory else { return nil }
        return item.path
    }

    private var entries: [ZipContents.Member] { contents?.children[folder] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("上一级", systemImage: "chevron.left") {
                    if folder.isEmpty { close() }
                    else { navigate((folder as NSString).deletingLastPathComponent) }
                }.labelStyle(.iconOnly)
                Text(archive.filename + (folder.isEmpty ? "" : " / " + folder))
                    .lineLimit(1).truncationMode(.middle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("关闭归档", systemImage: "xmark.circle", action: close)
                    .labelStyle(.iconOnly)
            }
            .padding(9)
            .buttonStyle(.borderless)
            Divider()
            if contents != nil, !entries.isEmpty {
                List(entries, selection: $selection) { item in
                    HStack {
                        Label(item.name, systemImage: item.isDirectory ? "folder" : "doc").lineLimit(1)
                        Spacer()
                        if item.isDirectory {
                            Button("打开文件夹", systemImage: "chevron.right") { navigate(item.path) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        } else if let size = item.size, size >= 0 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if item.isDirectory { navigate(item.path) } }
                    .tag(item.id)
                    .onDrag {
                        let paths = selection.contains(item.id) ? selection : [item.id]
                        return ArchiveDrag(archive: archive.url, modified: archive.modified, size: archive.size,
                                           folder: folder, members: paths).provider()
                    }
                }
            } else if let readError {
                ContentUnavailableView(readError, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if contents != nil {
                ContentUnavailableView("空文件夹", systemImage: "folder").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在读取归档…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(message ?? "\(entries.count) 项").lineLimit(1).truncationMode(.tail)
                Spacer()
                Button("解压所选…", action: chooseDestination).disabled(selection.isEmpty || browser.busy)
            }
            .font(.caption)
            .padding(8)
        }
        .task(id: previewPath) {
            browser.archivePreview = nil
            guard let path = previewPath else { return }
            let archive = self.archive
            let cache = previewCache
            let worker = Task.detached { try cache.read(path, from: archive) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let entry): browser.archivePreview = entry
            case .failure(let error): message = error.localizedDescription
            }
        }
        .task(id: archive.id) {
            let url = archive.url
            let worker = Task.detached { try ZipContents(archive: url) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let contents):
                self.contents = contents
                browser.didOpenArchive(archive)
                if contents.skipped > 0 { message = "跳过 \(contents.skipped) 个不支持的条目" }
            case .failure(let error): readError = error.localizedDescription
            }
        }
    }

    private func navigate(_ next: String) {
        folder = next
        selection.removeAll()
        message = nil
    }

    private func chooseDestination() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.prompt = "解压"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = browser.directory
        let paths = selection
        let selectedFolder = folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            browser.extractZip(archive, paths: paths, folder: selectedFolder, into: destination) { count in
                message = "已解压 \(count) 项 · \(destination.lastPathComponent)"
            }
        }
    }
}

struct ArchiveDrag: Codable, Sendable {
    static let type = UTType(exportedAs: "local.perchfiles.archive-members", conformingTo: .data)
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    let archive: URL
    let modified: Date?
    let size: Int?
    let folder: String
    let members: Set<String>

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func archiveEntry() -> FileEntry? {
        guard archive.isFileURL, ZipContents.supports(archive), !members.isEmpty else { return nil }
        let entry = FileEntry.read(archive)
        return entry.modified == modified && entry.size == size ? entry : nil
    }
}

private final class ArchivePreviewCache: Sendable {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("wfolder-preview-" + UUID().uuidString,
                                                                                   isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: root) }

    func read(_ path: String, from archive: FileEntry) throws -> FileEntry {
        let current = FileEntry.read(archive.url)
        guard current.modified == archive.modified, current.size == archive.size else { throw ZipError.changed }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try ZipContents.copyParts([path: target], from: archive.url)
            try Task.checkCancellation()
            return FileEntry.read(target)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
