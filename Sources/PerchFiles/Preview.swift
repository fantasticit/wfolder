import AVKit
import PDFKit
import QuickLookUI
import SwiftUI

struct PreviewPane: View {
    let model: BrowserModel
    let openFolder: (FileEntry) -> Void
    @ViewState private var showInfo = false

    var body: some View {
        let entry = model.selected
        VStack(spacing: 0) {
            HStack {
                Text("预览").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if let entry, !entry.isFolder {
                    if model.isStash {
                        Button("用默认应用打开", systemImage: "square.and.pencil") { model.openWithDefaultApp(entry) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("用默认应用打开，可编辑的文件可在其中修改")
                    }
                    Button { model.expandedPreview = entry } label: {
                        Label("放大预览", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("放大预览（空格）")
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 36)
            Divider()
            if let entry {
                surface(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(10)
                Divider()
                summary(entry)
            } else if !model.selectedIDs.isEmpty {
                ContentUnavailableView("已选 \(model.selectedIDs.count) 项", systemImage: "square.on.square")
                    .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("选择要预览的文件", systemImage: "doc.viewfinder")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("预览面板")
        .onChange(of: entry?.id) { showInfo = false }
    }

    @ViewBuilder private func surface(_ entry: FileEntry) -> some View {
        if entry.isFolder {
            VStack(spacing: 12) {
                PreviewFileIcon(entry: entry, size: 78)
                    .accessibilityHidden(true)
                Button("打开文件夹") { openFolder(entry) }
            }
        } else {
            FilePreview(entry: entry)
        }
    }

    private func summary(_ entry: FileEntry) -> some View {
        HStack(spacing: 8) {
            PreviewFileIcon(entry: entry, size: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.name)
                Text(entry.size == nil ? entry.kind : "\(entry.kind) · \(entry.sizeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("文件信息", systemImage: "info.circle") { showInfo.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("文件信息")
                .popover(isPresented: $showInfo, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(entry.name).font(.headline).lineLimit(2)
                        Divider()
                        LabeledContent("类型", value: entry.kind)
                        if entry.size != nil { LabeledContent("大小", value: entry.sizeLabel) }
                        if let modified = entry.modified {
                            LabeledContent("修改时间", value: modified.formatted(date: .abbreviated, time: .shortened))
                        }
                        if !entry.url.pathExtension.isEmpty && !entry.isFolder {
                            LabeledContent("扩展名", value: "." + entry.url.pathExtension)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(width: 280)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct FilePreview: View {
    let entry: FileEntry
    @ViewState private var loaded: Loaded?

    private struct Loaded {
        let entry: FileEntry
        let data: PreviewData
    }

    var body: some View {
        Group {
            switch loaded?.entry == entry ? loaded?.data : nil {
            case .text(let text, let monospaced, let highlights):
                if text.isEmpty {
                    Text("空文件").foregroundStyle(.secondary)
                } else {
                    TextPreview(entry: entry, text: text, monospaced: monospaced, highlights: highlights)
                }
            case .paged(let source):
                PagedPreview(source: source).id(source.id)
            case .image(let image):
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("图片预览")
            case .pdf(let pdf):
                PDFPreview(document: pdf.document)
                    .accessibilityLabel("PDF 预览")
            case .media(let kind):
                MediaPreview(entry: entry, kind: kind)
                    .id(entry.url)
            case .applicationIcon:
                PreviewFileIcon(entry: entry, size: 168).padding(16)
            case .quickLook:
                EmbeddedQuickLook(url: entry.url)
                    .accessibilityLabel("系统快速预览")
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry) {
            // Avoid opening intermediate files during rapid keyboard navigation.
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            let file = entry
            let task = Task.detached(priority: .userInitiated) { PreviewData.load(file) }
            let preview = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return }
            loaded = Loaded(entry: file, data: preview)
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        view.autoScales = true
        view.documentView?.enclosingScrollView?.scrollerStyle = .overlay
    }
}

private struct MediaPreview: View {
    let entry: FileEntry
    let kind: MediaKind
    @ViewState private var state: State = .loading

    private enum State {
        case loading
        case ready(AVPlayer, AVPlayerItem)
        case unavailable(String)
    }

    var body: some View {
        Group {
            switch state {
            case .ready(let player, let item):
                NativePlayer(player: player)
                    .accessibilityLabel("媒体预览")
                    .onReceive(item.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                        if status == .failed { failed(player) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
                        .receive(on: DispatchQueue.main)) { _ in
                        failed(player)
                    }
            case .unavailable(let title):
                ContentUnavailableView(title, systemImage: kind.symbol)
            case .loading:
                ProgressView().controlSize(.small)
            }
        }
        .task(id: entry) {
            pause()
            state = .loading
            let asset = AVURLAsset(url: entry.url)
            do {
                let tracks = try await asset.load(.tracks)
                try Task.checkCancellation()
                guard tracks.contains(where: { $0.mediaType == .video || $0.mediaType == .audio || $0.mediaType == .muxed }) else {
                    state = .unavailable("没有可播放的音视频轨道")
                    return
                }
                let playable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                if playable {
                    let item = AVPlayerItem(asset: asset)
                    state = .ready(AVPlayer(playerItem: item), item)
                } else {
                    state = .unavailable("无法预览此媒体")
                }
            } catch {
                if !Task.isCancelled { state = .unavailable("无法读取此媒体") }
            }
        }
        .onDisappear(perform: pause)
    }

    private func pause() {
        if case .ready(let player, _) = state { player.pause() }
    }

    private func failed(_ player: AVPlayer) {
        guard case .ready(let current, _) = state, current === player else { return }
        player.pause()
        state = .unavailable("无法播放此媒体")
    }
}

private struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct PreviewFileIcon: View {
    let entry: FileEntry
    let size: CGFloat
    @ViewState private var requestedEntry: FileEntry?
    @ViewState private var nativeIcon: NSImage?

    var body: some View {
        let native = requestedEntry == entry ? nativeIcon : nil
        Group {
            if let native {
                Image(nsImage: native).resizable().scaledToFit()
            } else if let placeholder = entry.placeholderIcon(size: size) {
                Image(nsImage: placeholder)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(nsColor: entry.glyph.tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(entry.iconAccessibilityLabel)
        .onChange(of: entry, initial: true) {
            requestedEntry = entry
            nativeIcon = nil
            guard entry.hasNativeIcon else { return }
            FileIcons.shared.load(for: entry) { image in
                if requestedEntry == entry { nativeIcon = image }
            }
        }
    }
}

private struct EmbeddedQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // Close after SwiftUI finishes removing the preview from its view graph.
        DispatchQueue.main.async { view.close() }
    }
}

struct ExpandedPreview: View {
    let entry: FileEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(entry.name, systemImage: entry.glyph.symbol)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            FilePreview(entry: entry)
                .frame(minWidth: 570, idealWidth: 720, minHeight: 400, idealHeight: 490)
        }
    }
}
