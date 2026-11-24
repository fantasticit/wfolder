import AppKit
import SwiftUI

struct FileTable: NSViewRepresentable {
    let actions: BrowserFileActions
    let listing: FileListing
    let selection: Set<URL>
    let settings: FileViewSettings
    let groupedRows: GroupedFileRows?
    let viewportWidth: CGFloat
    let showsLocation: Bool
    let sortColumn: FileColumn
    let ascending: Bool
    let focusRequest: Int
    let showDropHint: (FileDropHint?) -> Void
    private var model: BrowserModel { actions.model }

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BrowserTableView()
        table.style = .inset
        table.headerView = NSTableHeaderView()
        table.rowHeight = 29
        table.intercellSpacing = NSSize(width: 3, height: 1)
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.floatsGroupRows = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        table.selectionHighlightStyle = .regular
        table.setAccessibilityLabel("文件列表")
        for field in FileColumn.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(field.rawValue))
            column.title = field.rawValue
            column.width = Self.width(for: field)
            column.minWidth = field == .name ? 105 : 60
            column.maxWidth = 3000
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        let coordinator = context.coordinator
        table.delegate = coordinator
        table.dataSource = coordinator
        table.controller = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow(_:))
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = FileDropScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        actions.configureDrop(in: scroll) { [weak table, weak coordinator] point in
            guard let table, let coordinator else { return nil }
            let row = table.row(at: table.convert(point, from: nil))
            guard let entry = coordinator.entry(at: row), entry.isFolder else { return nil }
            return entry.url
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? BrowserTableView else { return }
        (scroll as? FileDropScrollView)?.showHint = showDropHint
        let coordinator = context.coordinator
        coordinator.applying = true
        defer { coordinator.applying = false }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            if focusRequest > 0 {
                DispatchQueue.main.async { [weak table] in
                    if let table { table.window?.makeFirstResponder(table) }
                }
            }
        }
        let directoryChanged = coordinator.directory != model.directory
        if directoryChanged {
            coordinator.directory = model.directory
            coordinator.needsScrollReset = true
        }
        updateColumns(table)
        let listingChanged = coordinator.listingID != listing.id
        let groupingChanged = coordinator.groupedRows?.id != groupedRows?.id
        let locationChanged = coordinator.showsLocation != showsLocation
        let extensionsChanged = coordinator.showExtensions != settings.showExtensions
        coordinator.showExtensions = settings.showExtensions
        let rowHeight: CGFloat = showsLocation ? (settings.compactRows ? 36 : 42) : (settings.compactRows ? 22 : 29)
        if table.rowHeight != rowHeight { table.rowHeight = rowHeight }
        if locationChanged {
            coordinator.showsLocation = showsLocation
            coordinator.needsScrollReset = true
        }
        if listingChanged || groupingChanged || locationChanged || extensionsChanged {
            coordinator.listingID = listing.id
            coordinator.entries = listing.entries
            coordinator.groupedRows = groupedRows
            table.reloadData()
        }
        if coordinator.needsScrollReset, directoryChanged || listingChanged || locationChanged {
            // The fixed header overlaps the clip view, so zero is below the true scroll origin.
            scroll.tile()
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: -clip.contentInsets.top))
            scroll.reflectScrolledClipView(clip)
            coordinator.needsScrollReset = listing.entries.isEmpty
        }
        if let column = table.tableColumns.first(where: { $0.identifier.rawValue == sortColumn.rawValue }),
           table.highlightedTableColumn != column
            || coordinator.ascending != ascending {
            if let previous = table.highlightedTableColumn { table.setIndicatorImage(nil, in: previous) }
            table.highlightedTableColumn = column
            let indicator = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down",
                                    accessibilityDescription: ascending ? "升序" : "降序")?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            table.setIndicatorImage(indicator, in: column)
            coordinator.ascending = ascending
        }
        let rowsByFile = groupedRows?.rowsByFile ?? listing.rows
        let rows = IndexSet(selection.compactMap { rowsByFile[$0] })
        if table.selectedRowIndexes != rows {
            table.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { table.scrollRowToVisible(first) }
        }
    }

    private func updateColumns(_ table: NSTableView) {
        let otherWidth = FileColumn.allCases.reduce(CGFloat(0)) { result, field in
            guard field != .name, !settings.hiddenColumns.contains(field) else { return result }
            return result + (settings.columnWidths[field] ?? Self.width(for: field)) + table.intercellSpacing.width
        }
        for column in table.tableColumns {
            guard let field = FileColumn(rawValue: column.identifier.rawValue) else { continue }
            let hidden = field != .name && settings.hiddenColumns.contains(field)
            if column.isHidden != hidden { column.isHidden = hidden }
            guard !hidden else { continue }
            let defaultWidth = field == .name ? max(105, viewportWidth - otherWidth - 18) : Self.width(for: field)
            let width = settings.columnWidths[field] ?? defaultWidth
            let constrained = min(column.maxWidth, max(column.minWidth, width))
            if abs(column.width - constrained) > 0.5 { column.width = constrained }
        }
    }

    static func width(for field: FileColumn) -> CGFloat {
        switch field {
        case .name: return 240
        case .kind: return 108
        case .modified: return 127
        case .size: return 77
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let actions: BrowserFileActions
        var model: BrowserModel { actions.model }
        var entries: [FileEntry] = []
        var groupedRows: GroupedFileRows?
        var listingID: UUID?
        var directory: URL?
        var needsScrollReset = false
        var applying = false
        var ascending: Bool?
        var focusRequest = 0
        var showsLocation = false
        var showExtensions = true

        init(actions: BrowserFileActions) { self.actions = actions }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            entry(at: row)?.url as NSURL?
        }

        func numberOfRows(in tableView: NSTableView) -> Int { groupedRows?.rows.count ?? entries.count }

        func entry(at row: Int) -> FileEntry? {
            if let groupedRows {
                guard groupedRows.rows.indices.contains(row), case .item(let index) = groupedRows.rows[row] else { return nil }
                return entries[index]
            }
            return entries.indices.contains(row) ? entries[row] : nil
        }

        func entries(at rows: IndexSet) -> [FileEntry] { rows.compactMap { entry(at: $0) } }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            actions.activate()
            if let field = FileColumn(rawValue: tableColumn.identifier.rawValue) { model.sort(by: field) }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !applying, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let field = FileColumn(rawValue: column.identifier.rawValue) else { return }
            let width = column.width
            DispatchQueue.main.async { [weak self] in self?.model.viewSettings.columnWidths[field] = width }
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { heading(at: row) != nil }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entry(at: row) != nil }

        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            groupedRows == nil ? proposed : IndexSet(proposed.filter { entry(at: $0) != nil })
        }

        private func heading(at row: Int) -> String? {
            guard let rows = groupedRows?.rows, rows.indices.contains(row), case .heading(let heading) = rows[row] else { return nil }
            return heading
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let title = heading(at: row) {
                let identifier = NSUserInterfaceItemIdentifier("FileGroupHeading")
                let label = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
                    ?? NSTextField(labelWithString: "")
                label.identifier = identifier
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.stringValue = title
                return label
            }
            guard let tableColumn, let entry = entry(at: row),
                  let field = FileColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileCell
                ?? FileCell(field: field)
            cell.configure(entry, showsLocation: showsLocation, showExtensions: showExtensions)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table = notification.object as? NSTableView else { return }
            model.select(Set(entries(at: table.selectedRowIndexes).map(\.id)))
        }

        @objc func openClickedRow(_ table: NSTableView) {
            if let entry = entry(at: table.clickedRow) { actions.open(entry) }
        }


    }
}

final class BrowserTableView: NSTableView, FileDragSource {
    weak var controller: FileTable.Coordinator?
    var dragsFromStash: Bool { controller?.model.isStash == true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { controller?.actions.activateForTabNavigation() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        controller?.actions.activate()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return super.menu(for: event) }
        controller.actions.activate()
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard controller.entry(at: row) != nil else {
            return controller.actions.contextualMenu(for: [], showsLocation: controller.showsLocation)
        }
        window?.makeFirstResponder(self)
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return controller.actions.contextualMenu(for: controller.entries(at: selectedRowIndexes),
                                                 showsLocation: controller.showsLocation)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let controller,
           controller.actions.handleShortcut(event, items: controller.entries(at: selectedRowIndexes)) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let controller,
           controller.actions.handleSelectionKey(event, entry: selectedRowIndexes.count == 1 ? controller.entry(at: selectedRow) : nil) {
            return
        }
        super.keyDown(with: event)
    }

}

private final class FileCell: NSTableCellView {
    private let field: FileColumn
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var locationLabel: NSTextField?
    private var tint: NSColor = .secondaryLabelColor

    init(field: FileColumn) {
        self.field = field
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(field.rawValue)
        textField = label
        label.font = field == .name ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 12)
        updateColors()
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = field == .size ? .right : .left
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let leading: NSLayoutXAxisAnchor
        if field == .name {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            imageView = icon
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18)
            ])
            leading = icon.trailingAnchor
            let path = NSTextField(labelWithString: "")
            path.font = .systemFont(ofSize: 11)
            path.lineBreakMode = .byTruncatingMiddle
            path.maximumNumberOfLines = 1
            path.isHidden = true
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [label, path])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leading, constant: 7),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
                path.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
            ])
            locationLabel = path
            return
        } else {
            leading = leadingAnchor
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: field == .name ? 7 : 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: field == .size ? -11 : -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private var iconEntry: FileEntry?
    private var usesNativeIcon = false

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        label.textColor = selected ? .alternateSelectedControlTextColor : field == .name ? .labelColor : .secondaryLabelColor
        icon.contentTintColor = usesNativeIcon ? nil : selected ? .alternateSelectedControlTextColor : tint
        locationLabel?.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    func configure(_ entry: FileEntry, showsLocation: Bool, showExtensions: Bool) {
        switch field {
        case .name:
            label.stringValue = entry.displayName(showExtensions: showExtensions)
            icon.image = entry.placeholderIcon(size: 17)
            tint = entry.glyph.tint
            iconEntry = entry.hasNativeIcon ? entry : nil
            usesNativeIcon = false
            icon.setAccessibilityLabel(entry.iconAccessibilityLabel)
            if entry.hasNativeIcon {
                FileIcons.shared.load(for: entry) { [weak self] image in
                    guard let self, self.iconEntry == entry else { return }
                    self.usesNativeIcon = true
                    self.icon.image = image
                    self.updateColors()
                }
            }
            updateColors()
            let path = entry.url.deletingLastPathComponent().path
            if let locationLabel {
                locationLabel.isHidden = !showsLocation
                locationLabel.stringValue = showsLocation ? (path as NSString).abbreviatingWithTildeInPath : ""
            }
            toolTip = showsLocation ? entry.filename + "\n" + path : entry.filename
            return
        case .kind:
            label.stringValue = entry.kind
        case .modified:
            label.stringValue = entry.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        case .size:
            label.stringValue = entry.sizeLabel
        }
        toolTip = label.stringValue
    }
}
