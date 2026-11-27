import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum VersionRaster {
    struct Pair: Sendable {
        let left: CGImage?
        let right: CGImage?
        let differences: CGImage?
        let changed: Int
        let samples: Int
        let pages: Int
    }

    static func supports(_ entry: FileEntry) -> Bool {
        entry.url.pathExtension.lowercased() == "pdf" || entry.contentType?.conforms(to: .image) == true
    }

    static func compare(_ left: URL, _ right: URL, page: Int) throws -> Pair {
        let a = try render(left, page: page)
        let b = try render(right, page: page)
        guard let size = [a.image, b.image].compactMap({ $0 }).first else { throw CocoaError(.fileReadCorruptFile) }
        let width = max(a.image?.width ?? 0, b.image?.width ?? 0, size.width)
        let height = max(a.image?.height ?? 0, b.image?.height ?? 0, size.height)
        guard let first = pixels(a.image, width: width, height: height),
              let second = pixels(b.image, width: width, height: height) else { throw CocoaError(.fileReadUnknown) }
        var diff = second
        var count = 0
        for pixel in stride(from: 0, to: diff.count, by: 4) {
            if pixel.isMultiple(of: 4096) { try Task.checkCancellation() }
            let changed = (0..<3).contains { abs(Int(first[pixel + $0]) - Int(second[pixel + $0])) > 16 }
            if changed {
                count += 1
                diff[pixel] = 230
                diff[pixel + 1] = second[pixel + 1] / 3
                diff[pixel + 2] = second[pixel + 2] / 3
            } else {
                for channel in 0..<3 { diff[pixel + channel] = UInt8(170 + Int(second[pixel + channel]) / 3) }
            }
        }
        let color = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = CGDataProvider(data: Data(diff) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: color, bitmapInfo: bitmap, provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
        return Pair(left: a.image, right: b.image, differences: image, changed: count,
                    samples: width * height, pages: max(a.count, b.count))
    }

    private static func render(_ url: URL, page: Int) throws -> (image: CGImage?, count: Int) {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let image = document.page(at: page).flatMap {
                raster($0.thumbnail(of: CGSize(width: 840, height: 840), for: .mediaBox))
            }
            return (image, document.pageCount)
        }
        guard let image = raster(url, limit: 960) else { throw CocoaError(.fileReadCorruptFile) }
        return (image, 1)
    }

    static func raster(_ url: URL, limit: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: limit]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func raster(_ image: NSImage) -> CGImage? {
        var bounds = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)
    }

    private static func pixels(_ image: CGImage?, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: image == nil ? 0.87 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let image {
                context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            }
            return true
        }
        return rendered ? data : nil
    }
}

struct VersionCompareView: View {
    @ViewState private var oldVersion: URL?
    @ViewState private var newVersion: URL?
    @ViewState private var page = 0
    @ViewState private var overlay = false
    @ViewState private var raster: VersionRaster.Pair?
    @ViewState private var folders: FolderComparison?
    @ViewState private var issue: String?
    @ViewState private var marking = false
    @ViewState private var notice: String?
    let history: DeliveryHistory
    let storage: ProfessionalStorage

    init(files: [URL], history: DeliveryHistory, storage: ProfessionalStorage) {
        _oldVersion = State(initialValue: files.count == 2 ? files[0] : nil)
        _newVersion = State(initialValue: files.count == 2 ? files[1] : files.count == 1 ? files.first : nil)
        self.history = history
        self.storage = storage
    }

    private var files: [URL] { [oldVersion, newVersion].compactMap { $0 } }

    private struct Request: Equatable {
        let files: [URL]
        let page: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                versionField("旧版本", url: $oldVersion)
                Divider().frame(height: 42)
                versionField("新版本", url: $newVersion)
            }
            HStack {
                let baselines = history.records.filter { $0.baseline != nil }
                if !baselines.isEmpty {
                    Menu("选用已交付的旧版本") {
                        ForEach(baselines) { record in
                            Button((record.entries.first?.path ?? "旧版本") + " · " +
                                   record.date.formatted(date: .abbreviated, time: .shortened)) {
                                oldVersion = record.baseline
                                page = 0
                            }
                        }
                    }
                    .fixedSize()
                }
                if oldVersion != nil && newVersion != nil {
                    Button("交换两边", systemImage: "arrow.left.arrow.right") {
                        let previous = oldVersion
                        oldVersion = newVersion
                        newVersion = previous
                        page = 0
                    }
                }
                Spacer()
                if let raster {
                    Toggle("高亮差异", isOn: $overlay)
                    if raster.pages > 1 {
                        Stepper("第 \(page + 1) / \(raster.pages) 页", value: $page, in: 0...max(0, raster.pages - 1))
                    }
                }
            }
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if files.count != 2 {
                ContentUnavailableView(oldVersion == nil ? "选择旧版本" : "选择新版本",
                    systemImage: "square.split.2x1",
                    description: Text("可以比较两份 PDF、两张图片或两个文件夹。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let folders {
                Text("\(folders.differences.count) 项不同").font(.callout)
                List(folders.differences) { item in
                    LabeledContent(item.path, value: item.status)
                }
                .listStyle(.inset)
            } else if let raster {
                Text("\(Double(raster.changed) / Double(raster.samples), format: .percent.precision(.fractionLength(2))) 采样像素有变化")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    image(raster.left)
                    Divider()
                    image(overlay ? raster.differences : raster.right)
                }
                HStack {
                    Spacer()
                    if let newVersion {
                        Button("保存新版本为交付基线") { mark(newVersion) }.disabled(marking)
                    }
                }
            } else if issue == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .task(id: Request(files: files, page: page)) { await compare(files, page: page) }
    }

    private func versionField(_ title: String, url: Binding<URL?>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                if let item = url.wrappedValue {
                    Text(item.lastPathComponent).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(item.path)
                }
            }
            Spacer()
            Button(url.wrappedValue == nil ? "选择…" : "更换…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.directoryURL = url.wrappedValue?.deletingLastPathComponent()
                panel.prompt = "选择" + title
                guard panel.runModal() == .OK else { return }
                url.wrappedValue = panel.url
                page = 0
            }
            .accessibilityLabel((url.wrappedValue == nil ? "选择" : "更换") + title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compare(_ files: [URL], page: Int) async {
        raster = nil
        folders = nil
        issue = nil
        notice = nil
        guard files.count == 2 else { return }
        do {
            if files.allSatisfy({ FileStamp($0)?.directory == true }) {
                let worker = Task.detached {
                    try FolderComparison(left: files[0], right: files[1], showHidden: false)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if !Task.isCancelled { folders = result }
            } else {
                let work = Task.detached { try VersionRaster.compare(files[0], files[1], page: page) }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if !Task.isCancelled { raster = result }
            }
        } catch where !Task.isCancelled { issue = "无法比较所选版本。\(error.localizedDescription)" }
        catch {}
    }

    private func image(_ image: CGImage?) -> some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Text("这一侧没有此页").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }

    private func mark(_ url: URL) {
        marking = true
        Task {
            defer { marking = false }
            do {
                let storage = storage
                let record = try await Task.detached {
                    let id = UUID()
                    let folder = storage.directory.appendingPathComponent("baselines/" + id.uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    let baseline = folder.appendingPathComponent(url.lastPathComponent)
                    do {
                        guard let stamp = FileStamp(url) else { throw TransferFileError.changedSource }
                        let digest = try VerifiedFile.sha256(url, stamp: stamp, copyingTo: baseline)
                        let entry = DeliveryRecord.Entry(path: url.lastPathComponent, bytes: stamp.bytes, sha256: digest)
                        return DeliveryRecord(id: id, date: .now, project: url.deletingLastPathComponent().path,
                            template: "已交付基线", target: url.deletingLastPathComponent(), archive: nil, sha256: nil,
                            entries: [entry], skipped: [], error: nil, baseline: baseline)
                    } catch {
                        try? FileManager.default.removeItem(at: folder)
                        throw error
                    }
                }.value
                history.append(record)
                notice = "已保存基线，可用于之后的版本对比。"
            } catch { issue = error.localizedDescription }
        }
    }
}
