import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct FileGrid: NSViewRepresentable {
    let actions: BrowserFileActions
    let listing: FileListing
    let selection: Set<URL>
    let mode: FileViewMode
    let showsLocation: Bool
    let showExtensions: Bool
    var showsCheckboxes = false
    let focusRequest: Int
    let showDropHint: (FileDropHint?) -> Void
    private var model: BrowserModel { actions.model }

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8

        let grid = BrowserCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        grid.collectionViewLayout = layout
        grid.autoresizingMask = [.width]
        grid.backgroundColors = [.clear]
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.setAccessibilityLabel("文件网格")
        grid.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        let coordinator = context.coordinator
        grid.dataSource = coordinator
        grid.delegate = coordinator
        grid.controller = coordinator
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = FileDropScrollView(frame: grid.frame)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = grid
        actions.configureDrop(in: scroll) { [weak grid, weak coordinator] point in
            guard let grid, let coordinator,
                  let path = grid.indexPathForItem(at: grid.convert(point, from: nil)),
                  let entry = coordinator.entry(at: path), entry.isFolder else { return nil }
            return entry.url
        }
        coordinator.startObserving(grid, in: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let grid = scroll.documentView as? BrowserCollectionView,
              let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        (scroll as? FileDropScrollView)?.showHint = showDropHint
        let coordinator = context.coordinator
        coordinator.applying = true
        defer { coordinator.applying = false }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak grid] in
                if let grid { grid.window?.makeFirstResponder(grid) }
            }
        }
        let directoryChanged = coordinator.directory != model.directory
        let dataChanged = coordinator.listingID != listing.id
        let styleChanged = coordinator.mode != mode || coordinator.showsLocation != showsLocation
            || coordinator.showExtensions != showExtensions || coordinator.showsCheckboxes != showsCheckboxes
        if dataChanged || styleChanged {
            grid.endMarquee()
            coordinator.listingID = listing.id
            coordinator.entries = listing.entries
            coordinator.mode = mode
            coordinator.showsLocation = showsLocation
            coordinator.showExtensions = showExtensions
            coordinator.showsCheckboxes = showsCheckboxes
            if dataChanged { grid.selectionAnchor = nil }
            layout.itemSize = FileGridItem.size(for: mode, showsLocation: showsLocation)
            grid.reloadData()
        }
        if directoryChanged {
            coordinator.directory = model.directory
            let clip = scroll.contentView
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
        }
        let selected = Set(selection.compactMap { listing.rows[$0] }.map { IndexPath(item: $0, section: 0) })
        if grid.selectionIndexPaths != selected {
            grid.selectionIndexPaths = selected
            if let first = selected.min() {
                DispatchQueue.main.async { [weak grid] in
                    guard let grid, grid.selectionIndexPaths == selected else { return }
                    grid.layoutSubtreeIfNeeded()
                    grid.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
                }
            }
        }
        coordinator.scheduleThumbnails()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        (view.documentView as? BrowserCollectionView)?.endMarquee()
        coordinator.stopObserving()
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        private static let thumbnails: NSCache<NSString, GridThumbnail> = {
            let cache = NSCache<NSString, GridThumbnail>()
            cache.countLimit = 256
            cache.totalCostLimit = 48 * 1024 * 1024
            return cache
        }()

        let actions: BrowserFileActions
        var entries: [FileEntry] = []
        var listingID: UUID?
        var directory: URL?
        var mode: FileViewMode = .details
        var showsLocation = false
        var showExtensions = true
        var showsCheckboxes = false
        var focusRequest = 0
        var applying = false

        private weak var grid: NSCollectionView?
        private var thumbnailRefreshScheduled = false
        private enum ThumbnailRequest {
            case image(QLThumbnailGenerator.Request)
            case video(Task<Void, Never>)

            func cancel() {
                switch self {
                case .image(let request): QLThumbnailGenerator.shared.cancel(request)
                case .video(let task): task.cancel()
                }
            }
        }
        private struct PendingThumbnail {
            let token: UUID
            let request: ThumbnailRequest
        }
        private var requests: [String: PendingThumbnail] = [:]
        private var failedKeys = Set<String>()

        init(actions: BrowserFileActions) { self.actions = actions }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            entry(at: indexPath)?.url as NSURL?
        }

        func startObserving(_ grid: NSCollectionView, in scroll: NSScrollView) {
            self.grid = grid
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleThumbnails),
                name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleThumbnails),
                name: NSView.frameDidChangeNotification, object: clip)
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            grid = nil
            for pending in requests.values { pending.request.cancel() }
            requests.removeAll()
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            entries.count
        }

        func entry(at path: IndexPath) -> FileEntry? {
            entries.indices.contains(path.item) ? entries[path.item] : nil
        }

        func selectedEntries(in grid: NSCollectionView) -> [FileEntry] {
            grid.selectionIndexPaths.sorted().compactMap { entry(at: $0) }
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
            if let item = item as? FileGridItem, let entry = entry(at: indexPath) {
                item.configure(entry, mode: mode, showsLocation: showsLocation, showExtensions: showExtensions)
                item.configureCheckbox(visible: showsCheckboxes, name: entry.filename) { [weak self, weak collectionView] in
                    guard let self, let collectionView, self.entry(at: indexPath)?.id == entry.id else { return }
                    self.actions.activate()
                    var selection = collectionView.selectionIndexPaths
                    selection.formSymmetricDifference([indexPath])
                    collectionView.selectionIndexPaths = selection
                    self.selectionChanged(in: collectionView)
                }
            }
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(in: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(in: collectionView)
        }

        func selectionChanged(in grid: NSCollectionView) {
            guard !applying else { return }
            actions.model.select(Set(grid.selectionIndexPaths.compactMap { entry(at: $0)?.id }))
        }

        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            scheduleThumbnails()
        }

        @objc func scheduleThumbnails() {
            guard !thumbnailRefreshScheduled else { return }
            thumbnailRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thumbnailRefreshScheduled = false
                self.loadVisibleThumbnails()
            }
        }

        private func loadVisibleThumbnails() {
            guard let grid, let window = grid.window else { return }
            let viewport = grid.visibleRect
            let scale = window.backingScaleFactor
            let edge: CGFloat = mode == .large ? 132 : 94
            let visible = grid.visibleItems().compactMap { item -> (String, FileGridItem, FileEntry)? in
                guard let item = item as? FileGridItem, item.view.frame.intersects(viewport),
                      let entry = item.entry, !entry.isFolder, !entry.isApplication,
                      entry.cloudStatus != .online, entry.sourceLanguage == nil,
                      entry.mediaKind == .video || entry.contentType?.conforms(to: .image) == true else { return nil }
                let key = "\(entry.url.path)\u{0}\(entry.modified?.timeIntervalSinceReferenceDate ?? -1)\u{0}\(entry.size ?? -1)\u{0}\(edge)\u{0}\(scale)"
                return (key, item, entry)
            }
            let visibleKeys = Set(visible.map(\.0))
            for (key, pending) in requests where !visibleKeys.contains(key) {
                pending.request.cancel()
                requests.removeValue(forKey: key)
            }
            failedKeys.formIntersection(visibleKeys)
            for (key, item, entry) in visible {
                if let thumb = Self.thumbnails.object(forKey: key as NSString) {
                    item.showThumbnail(thumb, key: key)
                } else if requests.count < 4, requests[key] == nil, !failedKeys.contains(key), item.thumbnailKey != key {
                    requestThumbnail(for: entry, key: key, edge: edge, scale: scale)
                }
            }
        }

        private func requestThumbnail(for entry: FileEntry, key: String, edge: CGFloat, scale: CGFloat) {
            let token = UUID()
            if entry.mediaKind == .video {
                let task = Task { [weak self] in
                    let video = await GridThumbnail.videoFrame(at: entry.url, pixelEdge: edge * scale)
                    guard !Task.isCancelled else { return }
                    self?.finishThumbnail(for: key, token: token, pixels: video?.pixels, scale: scale, duration: video?.duration)
                }
                requests[key] = PendingThumbnail(token: token, request: .video(task))
            } else {
                let request = QLThumbnailGenerator.Request(fileAt: entry.url,
                    size: CGSize(width: edge, height: edge), scale: scale, representationTypes: .thumbnail)
                requests[key] = PendingThumbnail(token: token, request: .image(request))
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                    let pixels = representation?.cgImage
                    DispatchQueue.main.async {
                        self?.finishThumbnail(for: key, token: token, pixels: pixels, scale: scale)
                    }
                }
            }
        }

        private func finishThumbnail(for key: String, token: UUID, pixels: CGImage?, scale: CGFloat, duration: TimeInterval? = nil) {
            guard requests[key]?.token == token else { return }
            requests.removeValue(forKey: key)
            if let pixels {
                let thumbnail = GridThumbnail(pixels: pixels, scale: scale, duration: duration)
                Self.thumbnails.setObject(thumbnail, forKey: key as NSString, cost: pixels.bytesPerRow * pixels.height)
            } else {
                failedKeys.insert(key)
            }
            scheduleThumbnails()
        }
    }
}

private final class GridThumbnail {
    let image: NSImage
    let duration: String?

    init(pixels: CGImage, scale: CGFloat, duration: TimeInterval?) {
        image = NSImage(cgImage: pixels, size: CGSize(width: CGFloat(pixels.width) / scale,
                                                     height: CGFloat(pixels.height) / scale))
        if let duration, duration.isFinite, duration >= 0, let seconds = Int(exactly: duration.rounded()) {
            if seconds >= 3600 {
                self.duration = "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60)
            } else {
                self.duration = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
            }
        } else {
            self.duration = nil
        }
    }

    static func videoFrame(at url: URL, pixelEdge: CGFloat) async -> (pixels: CGImage, duration: TimeInterval?)? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: pixelEdge, height: pixelEdge)
        generator.appliesPreferredTrackTransform = true
        return await withTaskCancellationHandler {
            guard !Task.isCancelled, let frame = try? await generator.image(at: .zero),
                  !Task.isCancelled else { return nil }
            let duration = try? await asset.load(.duration)
            return (frame.image, duration?.seconds)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}

private final class BrowserCollectionView: NSCollectionView, FileDragSource {
    private struct Marquee {
        let origin: NSPoint
        let originalSelection: Set<IndexPath>
        let modifiers: NSEvent.ModifierFlags
    }

    weak var controller: FileGrid.Coordinator?
    var dragsFromStash: Bool { controller?.actions.model.isStash == true }
    var selectionAnchor: Int?
    private var marquee: Marquee?
    private let marqueeView = GridMarqueeView(frame: .zero)

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { controller?.actions.activateForTabNavigation() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        controller?.actions.activate()
        endMarquee()
        guard let controller, !event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        layoutSubtreeIfNeeded()
        guard let path = indexPathForItem(at: point), let item = item(at: path) as? FileGridItem,
              item.intersectsContent(NSRect(x: point.x, y: point.y, width: 1, height: 1), in: self),
              let entry = controller.entry(at: path) else {
            window?.makeFirstResponder(self)
            marquee = Marquee(origin: point, originalSelection: selectionIndexPaths, modifiers: event.modifierFlags)
            return
        }
        if event.clickCount == 2 {
            controller.actions.open(entry)
            return
        }
        if event.modifierFlags.contains(.shift) {
            window?.makeFirstResponder(self)
            let anchor = selectionAnchor ?? selectionIndexPaths.min()?.item ?? path.item
            selectionAnchor = anchor
            let range = min(anchor, path.item)...max(anchor, path.item)
            let paths = Set(range.map { IndexPath(item: $0, section: path.section) })
            selectionIndexPaths = event.modifierFlags.contains(.command) ? selectionIndexPaths.union(paths) : paths
            controller.selectionChanged(in: self)
            return
        }
        selectionAnchor = path.item
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let marquee else {
            super.mouseDragged(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        guard marqueeView.superview != nil || hypot(location.x - marquee.origin.x, location.y - marquee.origin.y) >= 4
        else { return }
        if autoscroll(with: event) { layoutSubtreeIfNeeded() }
        updateMarquee(marquee, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let marquee else {
            super.mouseUp(with: event)
            return
        }
        let additive = marquee.modifiers.contains(.shift) || marquee.modifiers.contains(.command)
        if marqueeView.superview != nil {
            updateMarquee(marquee, to: convert(event.locationInWindow, from: nil))
        } else if !additive {
            applyMarqueeSelection([])
        }
        if !additive || selectionAnchor == nil { selectionAnchor = selectionIndexPaths.min()?.item }
        endMarquee()
    }

    func endMarquee() {
        marquee = nil
        marqueeView.removeFromSuperview()
    }

    private func updateMarquee(_ marquee: Marquee, to point: NSPoint) {
        let rect = NSRect(x: min(marquee.origin.x, point.x), y: min(marquee.origin.y, point.y),
                          width: max(1, abs(marquee.origin.x - point.x)),
                          height: max(1, abs(marquee.origin.y - point.y)))
        marqueeView.frame = rect
        if marqueeView.superview == nil { addSubview(marqueeView, positioned: .above, relativeTo: nil) }
        let attributes = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
        let paths = Set(attributes.compactMap { attribute -> IndexPath? in
            guard attribute.representedElementCategory == .item, rect.intersects(attribute.frame),
                  let path = attribute.indexPath else { return nil }
            if let item = item(at: path) as? FileGridItem, !item.intersectsContent(rect, in: self) { return nil }
            return path
        })
        if marquee.modifiers.contains(.shift) {
            applyMarqueeSelection(marquee.originalSelection.union(paths))
        } else if marquee.modifiers.contains(.command) {
            applyMarqueeSelection(marquee.originalSelection.symmetricDifference(paths))
        } else {
            applyMarqueeSelection(paths)
        }
    }

    private func applyMarqueeSelection(_ paths: Set<IndexPath>) {
        guard selectionIndexPaths != paths else { return }
        selectionIndexPaths = paths
        controller?.selectionChanged(in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return super.menu(for: event) }
        controller.actions.activate()
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            return controller.actions.contextualMenu(for: [], showsLocation: controller.showsLocation)
        }
        window?.makeFirstResponder(self)
        if !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            selectionAnchor = path.item
            controller.selectionChanged(in: self)
        }
        return controller.actions.contextualMenu(for: controller.selectedEntries(in: self),
                                                 showsLocation: controller.showsLocation)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let controller,
           controller.actions.handleShortcut(event, items: controller.selectedEntries(in: self)) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let controller,
           controller.actions.handleSelectionKey(event, entry: selectionIndexPaths.count == 1
               ? selectionIndexPaths.first.flatMap { controller.entry(at: $0) } : nil) { return }
        super.keyDown(with: event)
    }
}

private final class GridMarqueeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

private final class FileGridTile: NSView {
    var selected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            frame.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            frame.lineWidth = 1
            frame.stroke()
        }
    }
}

private final class FileGridPicture: NSImageView {
    var duration: String? { didSet { needsDisplay = true } }

    var imageBounds: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let scale = imageScaling == .scaleProportionallyDown ? min(1, fit) : fit
        let width = image.size.width * scale
        let height = image.size.height * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let duration else { return }
        let imageRect = imageBounds
        let text = NSAttributedString(string: duration, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        let size = text.size()
        let badgeWidth = size.width + 8
        let badgeHeight = size.height + 2
        guard imageRect.width >= badgeWidth + 6, imageRect.height >= badgeHeight + 6 else { return }
        let badge = NSRect(x: imageRect.maxX - badgeWidth - 3,
                           y: isFlipped ? imageRect.maxY - badgeHeight - 3 : imageRect.minY + 3,
                           width: badgeWidth, height: badgeHeight)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        text.draw(at: NSPoint(x: badge.minX + 4, y: badge.minY + 1))
    }
}

private final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
    private static let horizontalPadding: CGFloat = 7

    static func size(for mode: FileViewMode, showsLocation: Bool) -> NSSize {
        let large = mode == .large
        return NSSize(width: large ? 156 : 120, height: (large ? 182 : 146) + (showsLocation ? 16 : 0))
    }

    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private let picture = FileGridPicture()
    private let checkbox = FileSelectionCheckbox()
    private var pictureHeight: NSLayoutConstraint!
    private(set) var entry: FileEntry?
    private(set) var thumbnailKey: String?

    override func loadView() {
        let tile = FileGridTile()
        view = tile
        imageView = picture
        textField = nameLabel
        picture.imageScaling = .scaleProportionallyDown
        pictureHeight = picture.heightAnchor.constraint(equalToConstant: 62)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kindLabel.font = .systemFont(ofSize: 10)
        kindLabel.textColor = .secondaryLabelColor
        location.font = .systemFont(ofSize: 10)
        location.textColor = .secondaryLabelColor
        for label in [kindLabel, location] {
            label.alignment = .center
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [picture, nameLabel, kindLabel, location])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(stack)
        tile.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 5),
            checkbox.topAnchor.constraint(equalTo: tile.topAnchor, constant: 5),
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: Self.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -Self.horizontalPadding),
            stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8),
            picture.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pictureHeight,
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kindLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            location.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    func intersectsContent(_ rect: NSRect, in container: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        if rect.intersects(picture.convert(picture.imageBounds, to: container)) { return true }
        return [nameLabel, kindLabel, location].contains { label in
            guard !label.isHidden, !label.stringValue.isEmpty else { return false }
            let width = min(label.bounds.width, ceil(label.attributedStringValue.size().width) + 4)
            let text = NSRect(x: label.bounds.midX - width / 2, y: label.bounds.minY,
                              width: width, height: label.bounds.height)
            return rect.intersects(label.convert(text, to: container))
        }
    }

    private func applySelection() {
        (view as? FileGridTile)?.selected = isSelected
        nameLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .medium)
        checkbox.state = isSelected ? .on : .off
    }

    func configureCheckbox(visible: Bool, name: String, onToggle: @escaping () -> Void) {
        checkbox.configure(visible: visible, name: name, selected: isSelected, onToggle: onToggle)
    }

    func configure(_ entry: FileEntry, mode: FileViewMode, showsLocation: Bool, showExtensions: Bool) {
        self.entry = entry
        thumbnailKey = nil
        picture.duration = nil
        let large = mode == .large
        pictureHeight.constant = large ? 98 : 62
        picture.image = entry.placeholderIcon(size: large ? 62 : 43, detailed: true)
        picture.contentTintColor = entry.glyph.tint
        picture.setAccessibilityLabel(entry.iconAccessibilityLabel)
        picture.imageScaling = .scaleProportionallyDown
        if entry.hasNativeIcon {
            FileIcons.shared.load(for: entry) { [weak self] image in
                guard let self, self.entry == entry, self.thumbnailKey == nil else { return }
                self.picture.contentTintColor = nil
                self.picture.imageScaling = .scaleProportionallyUpOrDown
                self.picture.image = image
            }
        }
        nameLabel.preferredMaxLayoutWidth = Self.size(for: mode, showsLocation: showsLocation).width
            - 2 * Self.horizontalPadding
        nameLabel.stringValue = entry.displayName(showExtensions: showExtensions)
        kindLabel.stringValue = entry.cloudStatus.map { entry.kind + " · " + $0.rawValue } ?? entry.kind
        let path = entry.url.deletingLastPathComponent().path
        location.isHidden = !showsLocation
        location.stringValue = showsLocation ? (path as NSString).abbreviatingWithTildeInPath : ""
        let fullName = entry.filename
        let help = showsLocation ? fullName + "\n" + path : fullName
        let wrappedName = Self.wrapTooltip(fullName)
        let tooltip = showsLocation ? wrappedName + "\n" + Self.wrapTooltip(path) : wrappedName
        for target in [view, picture, nameLabel, kindLabel, location] {
            target.toolTip = tooltip
        }
        nameLabel.setAccessibilityHelp(help)
        picture.setAccessibilityHelp(help)
        applySelection()
    }

    private static func wrapTooltip(_ text: String) -> String {
        var lines: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 48, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(text[start..<end])
            start = end
        }
        return lines.joined(separator: "\n")
    }

    func showThumbnail(_ thumbnail: GridThumbnail, key: String) {
        guard thumbnailKey != key else { return }
        thumbnailKey = key
        picture.contentTintColor = nil
        picture.imageScaling = .scaleProportionallyDown
        picture.image = thumbnail.image
        picture.duration = thumbnail.duration
        picture.setAccessibilityLabel(thumbnail.duration.map { "视频缩略图 · 时长 \($0)" } ?? "缩略图")
    }
}
