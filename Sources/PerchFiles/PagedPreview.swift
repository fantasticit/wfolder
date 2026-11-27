import AppKit
import SwiftUI

struct PagedPreview: View {
    let source: any PreviewGridSource
    @ViewState private var status = PreviewStatus()

    var body: some View {
        VStack(spacing: 0) {
            PagedGrid(source: source, status: $status)
                .overlay {
                    if status.rows == 0 {
                        if let error = status.error {
                            Text(error).font(.caption).padding()
                        } else if status.finished {
                            Text("空文件").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            Divider()
            HStack(spacing: 6) {
                if status.rows > 0 {
                    Text(source.isTable
                         ? "\(status.rows.formatted()) 行 · \(status.columns.formatted()) 列"
                         : "\(status.rows.formatted()) 行")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if let error = status.error, status.rows > 0 {
                    Label("读取中断", systemImage: "exclamationmark.circle")
                        .help(error)
                } else if !status.finished {
                    ProgressView().controlSize(.mini)
                    Text("正在读取文件…")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

private struct PreviewStatus: Equatable {
    var rows = 0
    var columns = 0
    var finished = false
    var error: String?
}

private struct PagedGrid: NSViewRepresentable {
    let source: any PreviewGridSource
    @Binding var status: PreviewStatus

    func makeCoordinator() -> Coordinator { Coordinator(source: source, status: $status) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = PreviewTableView()
        table.style = .plain
        table.headerView = source.isTable ? NSTableHeaderView() : nil
        table.rowHeight = source.isTable ? 23 : 20
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.usesAlternatingRowBackgroundColors = source.isTable
        table.gridStyleMask = .solidVerticalGridLineMask
        table.gridColor = .separatorColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = source.isTable
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.dataSource = coordinator
        table.delegate = coordinator
        table.controller = coordinator
        table.setAccessibilityLabel(source.isTable ? "表格预览" : source.language == nil ? "文本预览" : "代码预览")

        let scroll = OverlayScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        scroll.documentView = table
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.setAccessibilityLabel(source.isTable ? "表格预览内容" : "预览内容")
        coordinator.start(in: scroll, table: table)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 220
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct Tile: Hashable {
            let page: Int
            let block: Int
        }

        private struct CachedPage {
            let rows: [[PreviewCell]]
            let bytes: Int
        }

        private let source: any PreviewGridSource
        private let status: Binding<PreviewStatus>
        private weak var table: PreviewTableView?
        private weak var scroll: NSScrollView?
        private var pages: [PreviewPageStart] = []
        private var rows = 0
        private var columns = 0
        private var textUnits = 0
        private var displayedColumns = 0
        private var totalColumnWidth: CGFloat = 0
        private var indexTask: Task<Void, Never>?
        private var indexObserver: Task<Void, Never>?
        private var viewportScheduled = false
        private var wanted: [Tile] = []
        private var loading: [Tile: Task<CachedPage, Error>] = [:]
        private var cache: [Tile: CachedPage] = [:]
        private var cacheOrder: [Tile] = []
        private var cacheBytes = 0
        private var failedTiles = Set<Tile>()

        init(source: any PreviewGridSource, status: Binding<PreviewStatus>) {
            self.source = source
            self.status = status
        }

        func start(in scroll: NSScrollView, table: PreviewTableView) {
            self.scroll = scroll
            self.table = table
            let numbering = makeColumn(index: -1, width: 58)
            table.addTableColumn(numbering)
            totalColumnWidth = numbering.width
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            viewportChanged()

            let (stream, continuation) = AsyncThrowingStream<PreviewIndexBatch, Error>.makeStream()
            let source = self.source
            indexTask = Task.detached(priority: .utility) {
                do {
                    try source.scan { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            indexObserver = Task { [weak self] in
                do {
                    for try await batch in stream {
                        guard !Task.isCancelled else { return }
                        self?.apply(batch)
                    }
                } catch {
                    if !Task.isCancelled { self?.report(error) }
                }
            }
        }

        func stop() {
            NotificationCenter.default.removeObserver(self)
            indexTask?.cancel()
            indexObserver?.cancel()
            for task in loading.values { task.cancel() }
            scroll = nil
            table = nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows }

        func value(at row: Int, column: Int) -> PreviewCell? {
            guard row >= 0, column >= 0 else { return nil }
            let key = Tile(page: row / PagedPreviewSource.pageRows, block: column / PagedPreviewSource.blockColumns)
            let pageRow = row % PagedPreviewSource.pageRows
            let blockColumn = column % PagedPreviewSource.blockColumns
            guard let page = cache[key], page.rows.indices.contains(pageRow),
                  page.rows[pageRow].indices.contains(blockColumn) else { return nil }
            return page.rows[pageRow][blockColumn]
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
            guard let column, let index = Int(column.identifier.rawValue) else { return nil }
            if index < 0 { return String(row + 1) }
            guard let cell = value(at: row, column: index) else { return nil }
            if cell.highlights.isEmpty { return cell.display }
            return SyntaxColors.attributed(cell.display, spans: cell.highlights,
                                           font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        }

        func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer,
                       tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
            guard source.isTable, let tableColumn, let index = Int(tableColumn.identifier.rawValue),
                  let cell = value(at: row, column: index) else { return "" }
            return String(cell.value.prefix(500))
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table else { return }
            totalColumnWidth = table.tableColumns.reduce(0) { $0 + $1.width }
            viewportChanged()
        }

        @objc private func viewportChanged() {
            guard !viewportScheduled else { return }
            viewportScheduled = true
            Task { [weak self] in
                guard let self else { return }
                self.viewportScheduled = false
                self.loadViewport()
            }
        }

        private func apply(_ batch: PreviewIndexBatch) {
            guard let table, let scroll else { return }
            let first = rows == 0
            pages.append(contentsOf: batch.pages)
            let rowsChanged = rows != batch.rows
            rows = batch.rows
            columns = batch.columns
            textUnits = batch.textUnits

            if displayedColumns == 0, columns > 0 {
                addColumns(upTo: min(columns, 32))
            } else if !source.isTable, let column = table.tableColumns.last, displayedColumns == 1 {
                let width = max(scroll.contentSize.width - 58, source.textWidth(for: textUnits))
                if column.width != width {
                    column.width = width
                    totalColumnWidth = 58 + column.width
                }
            }
            if rowsChanged { table.noteNumberOfRowsChanged() }
            fitDocument()
            if first, rows > 0 { (scroll as? OverlayScrollView)?.scrollToDocumentStart() }
            status.wrappedValue = PreviewStatus(rows: rows, columns: columns, finished: batch.finished,
                                               error: status.wrappedValue.error)
            viewportChanged()
        }

        private func report(_ error: Error) {
            var current = status.wrappedValue
            current.finished = true
            current.error = error.localizedDescription
            status.wrappedValue = current
        }

        private func fitDocument() {
            guard let table, let scroll else { return }
            let size = CGSize(width: max(totalColumnWidth, scroll.contentSize.width),
                              height: CGFloat(rows) * (table.rowHeight + table.intercellSpacing.height))
            if table.frame.size != size { table.setFrameSize(size) }
        }

        private func loadViewport() {
            guard let table, let scroll, rows > 0, displayedColumns > 0 else { return }
            fitDocument()
            let visible = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let visibleRows = table.rows(in: visible)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
            let firstPage = visibleRows.location / PagedPreviewSource.pageRows
            let lastPage = (NSMaxRange(visibleRows) - 1) / PagedPreviewSource.pageRows
            let visibleColumns = table.columnIndexes(in: visible)
            if let last = visibleColumns.last, last >= displayedColumns - 5, displayedColumns < columns {
                addColumns(upTo: min(columns, displayedColumns + 32))
                fitDocument()
            }
            let firstColumn = max(0, (visibleColumns.first ?? 1) - 1)
            let lastColumn = max(firstColumn, (visibleColumns.last ?? 1) - 1)
            let firstBlock = firstColumn / PagedPreviewSource.blockColumns
            let lastBlock = lastColumn / PagedPreviewSource.blockColumns

            let visibleTiles = (firstPage...lastPage).flatMap { page in
                (firstBlock...lastBlock).map { Tile(page: page, block: $0) }
            }
            wanted = visibleTiles
            if firstPage > 0 {
                wanted.append(Tile(page: firstPage - 1, block: firstBlock))
            }
            if lastPage + 1 < pages.count {
                wanted.append(Tile(page: lastPage + 1, block: firstBlock))
            }
            if (lastBlock + 1) * PagedPreviewSource.blockColumns < displayedColumns {
                wanted.append(Tile(page: firstPage, block: lastBlock + 1))
            }
            if firstBlock > 0 {
                wanted.append(Tile(page: firstPage, block: firstBlock - 1))
            }

            let needsVisibleTile = visibleTiles.contains {
                pages.indices.contains($0.page) && cache[$0] == nil && loading[$0] == nil && !failedTiles.contains($0)
            }
            for (key, task) in loading where !wanted.contains(key) || (needsVisibleTile && !visibleTiles.contains(key)) {
                task.cancel()
                loading.removeValue(forKey: key)
            }
            requestTiles()
        }

        private func requestTiles() {
            for key in wanted where loading.count < 2 {
                guard pages.indices.contains(key.page), cache[key] == nil, loading[key] == nil,
                      !failedTiles.contains(key) else { continue }
                let source = self.source
                let start = pages[key.page]
                let task = Task.detached(priority: .userInitiated) {
                    let rows = try source.readPage(at: start, block: key.block)
                    let bytes = rows.reduce(0) { length, row in
                        length + row.reduce(0) { $0 + $1.value.utf8.count + $1.display.utf8.count + $1.highlights.count * 24 + 64 }
                    }
                    return CachedPage(rows: rows, bytes: bytes)
                }
                loading[key] = task
                Task { [weak self] in
                    let result = await task.result
                    guard !task.isCancelled, let self else { return }
                    self.loading.removeValue(forKey: key)
                    switch result {
                    case .success(let page): self.cachePage(page, at: key)
                    case .failure(let error):
                        self.failedTiles.insert(key)
                        self.report(error)
                    }
                    self.requestTiles()
                }
            }
        }

        private func cachePage(_ page: CachedPage, at key: Tile) {
            cache[key] = page
            cacheOrder.append(key)
            cacheBytes += page.bytes
            while cache.count > 12 || cacheBytes > 16 * 1024 * 1024 {
                guard let index = cacheOrder.firstIndex(where: { !wanted.contains($0) }) else { break }
                let old = cacheOrder.remove(at: index)
                cacheBytes -= cache.removeValue(forKey: old)?.bytes ?? 0
            }
            guard let table else { return }
            let top = key.page * PagedPreviewSource.pageRows
            let bottom = min(rows, top + page.rows.count)
            let left = key.block * PagedPreviewSource.blockColumns + 1
            let right = min(displayedColumns + 1, left + PagedPreviewSource.blockColumns)
            if top < bottom, left < right {
                table.reloadData(forRowIndexes: IndexSet(integersIn: top..<bottom),
                                 columnIndexes: IndexSet(integersIn: left..<right))
            }
        }

        private func addColumns(upTo target: Int) {
            guard let table, let scroll, target > displayedColumns else { return }
            for index in displayedColumns..<target {
                let width = source.isTable ? 110 : max(scroll.contentSize.width - 58, source.textWidth(for: textUnits))
                let column = makeColumn(index: index, width: width)
                table.addTableColumn(column)
                totalColumnWidth += column.width
            }
            displayedColumns = target
        }

        private func makeColumn(index: Int, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = index < 0 ? "#" : Self.columnName(index)
            column.headerCell.alignment = index < 0 ? .right : .left
            let cell = NSTextFieldCell(textCell: "")
            if index < 0 {
                cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            } else if source.isMonospaced {
                cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            } else {
                cell.font = .systemFont(ofSize: 12)
            }
            cell.textColor = index < 0 ? .secondaryLabelColor : .labelColor
            cell.alignment = index < 0 ? .right : .left
            cell.isEditable = false
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byTruncatingTail
            column.dataCell = cell
            column.resizingMask = index >= 0 && source.isTable ? .userResizingMask : []
            column.minWidth = index < 0 ? width : 52
            column.maxWidth = index < 0 ? width : (source.isTable ? 600 : 50_000)
            column.width = width
            return column
        }

        private static func columnName(_ index: Int) -> String {
            var current = index
            var letters: [UInt8] = []
            repeat {
                letters.append(UInt8(current % 26) + 65)
                current = current / 26 - 1
            } while current >= 0
            return String(decoding: letters.reversed(), as: UTF8.self)
        }
    }
}

private final class PreviewTableView: NSTableView {
    weak var controller: PagedGrid.Coordinator?
    private var copiedValue: String?

    // Accessibility navigates the same viewport as the page cache.
    override func accessibilityRows() -> [any NSAccessibilityRow]? { super.accessibilityVisibleRows() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let columnIndex = column(at: point)
        guard tableColumns.indices.contains(columnIndex),
              let column = Int(tableColumns[columnIndex].identifier.rawValue),
              let cell = controller?.value(at: row(at: point), column: column) else {
            return super.menu(for: event)
        }
        copiedValue = cell.value
        let menu = NSMenu()
        let title = headerView == nil ? "复制此行文本" : "复制单元格"
        let action = NSMenuItem(title: title, action: #selector(copyCell), keyEquivalent: "")
        action.target = self
        menu.addItem(action)
        return menu
    }

    @objc private func copyCell() {
        guard let copiedValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedValue, forType: .string)
        self.copiedValue = nil
    }
}
