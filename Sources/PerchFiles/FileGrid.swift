import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileGrid: NSViewRepresentable {
    let actions: BrowserFileActions
    let listing: FileListing
    let selection: Set<URL>
    let mode: FileViewMode
    let showsLocation: Bool
    let showExtensions: Bool
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
            || coordinator.showExtensions != showExtensions
        if dataChanged || styleChanged {
            coordinator.listingID = listing.id
            coordinator.entries = listing.entries
            coordinator.mode = mode
            coordinator.showsLocation = showsLocation
            coordinator.showExtensions = showExtensions
            if dataChanged { grid.selectionAnchor = nil }
            layout.itemSize = mode == .large
                ? NSSize(width: 156, height: showsLocation ? 157 : 141)
                : NSSize(width: 112, height: showsLocation ? 117 : 101)
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
        var focusRequest = 0
        var applying = false

        private weak var grid: NSCollectionView?
        private var thumbnailRefreshScheduled = false
        private struct PendingThumbnail {
            let token: UUID
            let request: QLThumbnailGenerator.Request
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
            for pending in requests.values { QLThumbnailGenerator.shared.cancel(pending.request) }
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
            let edge = mode == .large ? 124 : 84
            let visible = grid.visibleItems().compactMap { item -> (String, FileGridItem, FileEntry)? in
                guard let item = item as? FileGridItem, item.view.frame.intersects(viewport),
                      let entry = item.entry, !entry.isFolder else { return nil }
                let key = "\(entry.url.path)\u{0}\(entry.modified?.timeIntervalSinceReferenceDate ?? -1)\u{0}\(entry.size ?? -1)\u{0}\(edge)\u{0}\(scale)"
                return (key, item, entry)
            }
            let visibleKeys = Set(visible.map(\.0))
            for (key, pending) in requests where !visibleKeys.contains(key) {
                QLThumbnailGenerator.shared.cancel(pending.request)
                requests.removeValue(forKey: key)
            }
            failedKeys.formIntersection(visibleKeys)
            for (key, item, entry) in visible {
                if let thumb = Self.thumbnails.object(forKey: key as NSString) {
                    item.showThumbnail(thumb.image, key: key)
                } else if requests.count < 4, requests[key] == nil, !failedKeys.contains(key), item.thumbnailKey != key {
                    let request = QLThumbnailGenerator.Request(fileAt: entry.url,
                        size: CGSize(width: edge, height: edge), scale: scale, representationTypes: .thumbnail)
                    let token = UUID()
                    requests[key] = PendingThumbnail(token: token, request: request)
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                        let image = representation?.cgImage
                        DispatchQueue.main.async {
                            guard let self, self.requests[key]?.token == token else { return }
                            self.requests.removeValue(forKey: key)
                            if let image {
                                let cost = image.bytesPerRow * image.height
                                let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                                let thumbnail = NSImage(cgImage: image, size: size)
                                Self.thumbnails.setObject(GridThumbnail(image: thumbnail), forKey: key as NSString, cost: cost)
                            } else {
                                self.failedKeys.insert(key)
                            }
                            self.scheduleThumbnails()
                        }
                    }
                }
            }
        }
    }
}

private final class GridThumbnail {
    let image: NSImage
    init(image: NSImage) { self.image = image }
}

private final class BrowserCollectionView: NSCollectionView, FileDragSource {
    weak var controller: FileGrid.Coordinator?
    var dragsFromStash: Bool { controller?.actions.model.isStash == true }
    var selectionAnchor: Int?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { controller?.actions.activateForTabNavigation() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        controller?.actions.activate()
        guard let controller, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
              let entry = controller.entry(at: path) else {
            if !event.modifierFlags.contains(.shift) { selectionAnchor = nil }
            super.mouseDown(with: event)
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

private final class FileGridTile: NSView {
    var selected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
    }
}

private final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")
    private let nameLabel = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private let picture = NSImageView()
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
        location.font = .systemFont(ofSize: 10)
        for label in [nameLabel, location] {
            label.alignment = .center
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [picture, nameLabel, location])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8),
            picture.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pictureHeight,
            nameLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            location.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    private func applySelection() {
        (view as? FileGridTile)?.selected = isSelected
        nameLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        location.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    func configure(_ entry: FileEntry, mode: FileViewMode, showsLocation: Bool, showExtensions: Bool) {
        self.entry = entry
        thumbnailKey = nil
        let large = mode == .large
        pictureHeight.constant = large ? 102 : 62
        let glyph = entry.glyph
        picture.image = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: large ? 60 : 40, weight: .regular))
        picture.contentTintColor = glyph.tint
        picture.setAccessibilityLabel("文件图标")
        nameLabel.stringValue = entry.displayName(showExtensions: showExtensions)
        let path = entry.url.deletingLastPathComponent().path
        location.isHidden = !showsLocation
        location.stringValue = showsLocation ? (path as NSString).abbreviatingWithTildeInPath : ""
        view.toolTip = showsLocation ? entry.filename + "\n" + path : entry.filename
        applySelection()
    }

    func showThumbnail(_ image: NSImage, key: String) {
        guard thumbnailKey != key else { return }
        thumbnailKey = key
        picture.contentTintColor = nil
        picture.image = image
        picture.setAccessibilityLabel("缩略图")
    }
}
