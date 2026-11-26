import Foundation
import SQLite3

struct XLSXSheetSource: PreviewGridSource {
    let id = UUID()
    let isTable = true
    let workbook: XLSXWorkbook
    let sheet: XLSXWorkbook.Sheet
    private let dictionary: XLSXTemporaryDirectory

    init(workbook: XLSXWorkbook, sheet: XLSXWorkbook.Sheet) throws {
        self.workbook = workbook
        self.sheet = sheet
        dictionary = try XLSXTemporaryDirectory()
    }

    func scan(_ publish: @escaping (PreviewIndexBatch) -> Void) throws {
        let xml = try XLSXTemporaryDirectory()
        let sheetFile = xml.file("worksheet.xml")
        let stringsFile = xml.file("strings.xml")
        var parts = [sheet.path: sheetFile]
        if let strings = workbook.sharedStrings, strings != sheet.path { parts[strings] = stringsFile }
        try ZipContents.copyParts(parts, from: workbook.url, maxPartBytes: 1 << 30)

        let db = try XLSXDatabase(url: dictionary.file("cells.sqlite"), writable: true)
        try db.execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE strings (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE cells (r INTEGER, c INTEGER, value TEXT NOT NULL, shared INTEGER, PRIMARY KEY (r, c)) WITHOUT ROWID;
            BEGIN;
            """)
        if let strings = workbook.sharedStrings, strings != sheet.path {
            let reader = try XLSXSheetXML(db: db, kind: .strings)
            try reader.parse(stringsFile)
        }
        let reader = try XLSXSheetXML(db: db, kind: .sheet, publish: publish)
        try reader.parse(sheetFile)
        try reader.publishIndex(finished: true)
    }

    func readPage(at start: PreviewPageStart, block: Int) throws -> [[PreviewCell]] {
        let db = try XLSXDatabase(url: dictionary.file("cells.sqlite"), writable: false)
        let query = try db.prepare("""
            SELECT cells.r, cells.c, COALESCE(strings.value, cells.value)
            FROM cells LEFT JOIN strings ON strings.id = cells.shared
            WHERE cells.r >= ? AND cells.r < ? AND cells.c >= ? AND cells.c < ?;
            """)
        let row = Int(start.offset)
        let column = block * PagedPreviewSource.blockColumns
        try query.bind(row, to: 1)
        try query.bind(row + PagedPreviewSource.pageRows, to: 2)
        try query.bind(column, to: 3)
        try query.bind(column + PagedPreviewSource.blockColumns, to: 4)
        let blank = PreviewCell("", singleLine: true)
        var rows = Array(repeating: Array(repeating: blank, count: PagedPreviewSource.blockColumns),
                         count: PagedPreviewSource.pageRows)
        while try query.next() {
            try Task.checkCancellation()
            let rowIndex = query.integer(0) - row
            let colIndex = query.integer(1) - column
            rows[rowIndex][colIndex] = PreviewCell(query.string(2), singleLine: true)
        }
        return rows
    }
}

private final class XLSXSheetXML: XLSXXMLReader {
    enum Kind { case strings, sheet }
    private enum Content { case none, value, formula, text }

    private struct Cell {
        let column: Int
        let type: String?
        var value = ""
        var formula = ""
    }

    private let db: XLSXDatabase
    private let kind: Kind
    private let insert: XLSXStatement
    private let publish: (PreviewIndexBatch) -> Void
    private var row = -1
    private var nextColumn = 0
    private var insideRow = false
    private var cell: Cell?
    private var content = Content.none
    private var phonetic = false
    private var insideString = false
    private var string = ""
    private var stringCount = 0
    private var rows = 0
    private var columns = 0
    private var publishedPages = 0
    private var nextUpdate: UInt64 = 0

    init(db: XLSXDatabase, kind: Kind, publish: @escaping (PreviewIndexBatch) -> Void = { _ in }) throws {
        self.db = db
        self.kind = kind
        self.publish = publish
        insert = try db.prepare(kind == .strings
            ? "INSERT INTO strings (id, value) VALUES (?, ?);"
            : "INSERT OR REPLACE INTO cells (r, c, value, shared) VALUES (?, ?, ?, ?);")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { abort(parser, because: CancellationError()); return }
        switch localName(elementName) {
        case "si" where kind == .strings:
            insideString = true
            string = ""
        case "row" where kind == .sheet:
            row = attributes["r"].flatMap(Int.init).map { $0 > 0 ? $0 - 1 : -1 } ?? (row + 1)
            insideRow = (0..<1_048_576).contains(row)
            nextColumn = 0
        case "c" where insideRow:
            let index = attributes["r"].flatMap(Self.columnIndex) ?? nextColumn
            guard (0..<16_384).contains(index) else { return }
            nextColumn = index + 1
            cell = Cell(column: index, type: attributes["t"])
        case "rPh": phonetic = true
        case "t" where !phonetic && (insideString || cell?.type == "inlineStr"): content = .text
        case "v" where cell != nil: content = .value
        case "f" where cell != nil: content = .formula
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) {
        switch content {
        case .text where insideString: string += text
        case .value, .text: cell?.value += text
        case .formula: cell?.formula += text
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if let value = String(data: block, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        do {
            switch localName(elementName) {
            case "si" where insideString:
                insideString = false
                try insert.bind(stringCount, to: 1)
                try insert.bind(string, to: 2)
                try insert.run()
                stringCount += 1
            case "c":
                if let cell { try store(cell) }
                cell = nil
            case "row" where insideRow:
                insideRow = false
                try publishIndex(finished: false)
            case "rPh": phonetic = false
            case "v", "f", "t": content = .none
            default: break
            }
        } catch {
            abort(parser, because: error)
        }
    }

    private func store(_ cell: Cell) throws {
        guard !cell.value.isEmpty || !cell.formula.isEmpty else { return }
        let value: String
        if cell.type == "b" {
            value = cell.value == "1" ? "TRUE" : cell.value == "0" ? "FALSE" : cell.value
        } else if cell.value.isEmpty {
            value = "=" + cell.formula
        } else {
            value = cell.value
        }
        try insert.bind(row, to: 1)
        try insert.bind(cell.column, to: 2)
        try insert.bind(value, to: 3)
        if cell.type == "s", let index = Int(cell.value) { try insert.bind(index, to: 4) }
        try insert.run()
        rows = max(rows, row + 1)
        columns = max(columns, cell.column + 1)
    }

    func publishIndex(finished: Bool) throws {
        let pageSize = PagedPreviewSource.pageRows
        let visibleRows = finished ? rows : rows / pageSize * pageSize
        let pageCount = (visibleRows + pageSize - 1) / pageSize
        let now = DispatchTime.now().uptimeNanoseconds
        guard finished || (pageCount > publishedPages && now >= nextUpdate) else { return }
        try db.execute(finished ? "COMMIT;" : "COMMIT; BEGIN;")
        let starts = (publishedPages..<pageCount).map {
            PreviewPageStart(offset: UInt64($0 * pageSize), syntaxState: nil)
        }
        publish(PreviewIndexBatch(pages: starts, rows: visibleRows, columns: columns, textUnits: 0, finished: finished))
        publishedPages = pageCount
        nextUpdate = now + 120_000_000
    }

    private static func columnIndex(_ reference: String) -> Int? {
        var value = 0
        for byte in reference.utf8 {
            guard (65...90).contains(byte) else { break }
            value = value * 26 + Int(byte) - 64
            guard value <= 16_384 else { return nil }
        }
        return value > 0 ? value - 1 : nil
    }
}

private final class XLSXDatabase {
    private let handle: OpaquePointer

    init(url: URL, writable: Bool) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        var handle: OpaquePointer?
        let result = url.withUnsafeFileSystemRepresentation { sqlite3_open_v2($0, &handle, flags, nil) }
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw XLSXError.invalid
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 500)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw XLSXError.invalid }
    }

    func prepare(_ sql: String) throws -> XLSXStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw XLSXError.invalid }
        return XLSXStatement(statement)
    }
}

private final class XLSXStatement {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_finalize(handle) }

    func bind(_ value: Int, to index: Int32) throws {
        guard sqlite3_bind_int64(handle, index, Int64(value)) == SQLITE_OK else { throw XLSXError.invalid }
    }

    func bind(_ value: String, to index: Int32) throws {
        guard sqlite3_bind_text(handle, index, value, -1, Self.transient) == SQLITE_OK else { throw XLSXError.invalid }
    }

    func run() throws {
        guard sqlite3_step(handle) == SQLITE_DONE else { throw XLSXError.invalid }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func next() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw XLSXError.invalid
        }
    }

    func integer(_ index: Int32) -> Int { Int(sqlite3_column_int64(handle, index)) }

    func string(_ index: Int32) -> String {
        sqlite3_column_text(handle, index).map { String(cString: $0) } ?? ""
    }
}
