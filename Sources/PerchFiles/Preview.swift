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
                ContentUnavailableView("选择要预览的文件", systemImage: "document.viewfinder")
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
                Image(systemName: "folder.fill")
                    .font(.system(size: 47))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Button("打开文件夹") { openFolder(entry) }
            }
        } else {
            FilePreview(entry: entry)
        }
    }

    private func summary(_ entry: FileEntry) -> some View {
        HStack(spacing: 8) {
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
            case .text(let text, let monospaced):
                if text.isEmpty {
                    Text("空文件").foregroundStyle(.secondary)
                } else {
                    TextPreview(entry: entry, text: text, monospaced: monospaced)
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
            case .media:
                MediaPreview(url: entry.url)
                    .id(entry.url)
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
    let url: URL
    @ViewState private var player: AVPlayer?
    @ViewState private var unavailable = false

    var body: some View {
        Group {
            if let player {
                NativePlayer(player: player)
                    .accessibilityLabel("媒体预览")
            } else if unavailable {
                EmbeddedQuickLook(url: url)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) == true
            guard !Task.isCancelled else { return }
            if playable { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
            else { unavailable = true }
        }
        .onDisappear { player?.pause() }
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

private struct EmbeddedQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
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
