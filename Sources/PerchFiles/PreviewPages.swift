import CoreFoundation
import Foundation

enum PreviewPageMode: Sendable {
    case delimited(separator: UInt16)
    case text(monospaced: Bool, language: SourceLanguage? = nil)

    var language: SourceLanguage? {
        if case .text(_, let language) = self { return language }
        return nil
    }

    var isTable: Bool {
        if case .delimited = self { return true }
        return false
    }
}

struct PreviewPageStart: Sendable {
    let offset: UInt64
    let syntaxState: SyntaxDelimiter?
}

struct PreviewIndexBatch: Sendable {
    let pages: [PreviewPageStart]
    let rows: Int
    let columns: Int
    let textUnits: Int
    let finished: Bool
}

struct PreviewCell: Sendable {
    let value: String
    let display: String
    var highlights: [SyntaxSpan] = []

    init(_ value: String, singleLine: Bool) {
        self.value = value
        if singleLine {
            let prefix = value.prefix(256)
            display = String(prefix)
                .replacingOccurrences(of: "\r\n", with: " ↵ ")
                .replacingOccurrences(of: "\n", with: " ↵ ")
                .replacingOccurrences(of: "\r", with: " ↵ ")
                + (prefix.endIndex == value.endIndex ? "" : "…")
        } else {
            display = value.contains("\t") ? value.replacingOccurrences(of: "\t", with: "    ") : value
        }
    }
}

protocol PreviewGridSource: Sendable {
    var id: UUID { get }
    var isTable: Bool { get }
    var isMonospaced: Bool { get }
    var language: SourceLanguage? { get }
    func textWidth(for units: Int) -> CGFloat
    func scan(_ publish: @escaping (PreviewIndexBatch) -> Void) throws
    func readPage(at start: PreviewPageStart, block: Int) throws -> [[PreviewCell]]
}

extension PreviewGridSource {
    var isMonospaced: Bool { false }
    var language: SourceLanguage? { nil }
    func textWidth(for units: Int) -> CGFloat { 0 }
}

struct PagedPreviewSource: PreviewGridSource {
    static let pageRows = 128
    static let blockColumns = 16

    let id = UUID()
    let mode: PreviewPageMode
    var isTable: Bool { mode.isTable }
    var language: SourceLanguage? { mode.language }
    var isMonospaced: Bool {
        if case .text(let monospaced, _) = mode { return monospaced }
        return false
    }
    private let file: PreviewFile
    private let encoding: PreviewEncoding
    private let start: UInt64
    private let sample: Data

    init?(url: URL, mode: PreviewPageMode) throws {
        let file = try PreviewFile(url)
        let sample = try file.read(at: 0, count: Int(min(file.size, 32 * 1024)))
        guard let (encoding, start) = PreviewEncoding.detect(sample, partial: UInt64(sample.count) < file.size) else {
            return nil
        }
        self.file = file
        self.mode = mode
        self.encoding = encoding
        self.start = start
        self.sample = sample
    }

    static func isTypeScriptText(_ url: URL) -> Bool {
        guard let file = try? PreviewFile(url),
              let sample = try? file.read(at: 0, count: 4096) else { return false }
        // A stream usually has a sync byte at each packet boundary, including Blu-ray's timestamp framing.
        for (offset, stride) in [(0, 188), (4, 192), (0, 204)] where sample.count > offset + 2 * stride {
            if (0..<3).allSatisfy({ sample[offset + $0 * stride] == 0x47 }) { return false }
        }
        guard let (encoding, start) = PreviewEncoding.detect(sample, partial: UInt64(sample.count) < file.size) else {
            return false
        }
        let text = encoding.decode(Data(sample.dropFirst(Int(start))))
        return text.unicodeScalars.allSatisfy {
            $0.value == 9 || $0.value == 10 || $0.value == 12 || $0.value == 13
                || ($0.value >= 32 && !(0x7f...0x9f).contains($0.value))
        }
    }

    func smallText(maxBytes: UInt64 = 256 * 1024) throws -> String? {
        guard !mode.isTable, file.size <= maxBytes else { return nil }
        let bytes = UInt64(sample.count) == file.size ? sample : try file.read(at: 0, count: Int(file.size))
        return encoding.decode(Data(bytes.dropFirst(Int(start))))
    }

    func scan(_ publish: @escaping (PreviewIndexBatch) -> Void) throws {
        let reader = PreviewRecordReader(file: file, encoding: encoding, offset: start)
        var pages: [PreviewPageStart] = []
        let syntax = mode.language.map(CodeSyntax.forLanguage)
        var state: SyntaxDelimiter?
        var pageText = ""
        var rows = 0
        var columns = 0
        var textUnits = 0
        var nextUpdate: UInt64 = 0

        while true {
            let offset = reader.offset
            guard let record = try reader.next(mode: mode, columns: syntax == nil ? nil : 0..<1) else { break }
            if rows % Self.pageRows == 0 {
                pages.append(PreviewPageStart(offset: offset, syntaxState: state))
            }
            if syntax != nil, let cell = record.cells.first {
                pageText += cell.display
                if record.lineEnded { pageText += "\n" }
            }
            rows += 1
            columns = max(columns, record.columns)
            textUnits = max(textUnits, record.textUnits)
            if rows % Self.pageRows == 0 {
                try Task.checkCancellation()
                if let syntax {
                    _ = syntax.scan(pageText, continuing: &state, highlights: false)
                    pageText.removeAll(keepingCapacity: true)
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= nextUpdate {
                    publish(PreviewIndexBatch(pages: pages, rows: rows, columns: columns,
                                              textUnits: textUnits, finished: false))
                    pages.removeAll(keepingCapacity: true)
                    nextUpdate = now + 120_000_000
                }
            }
        }
        publish(PreviewIndexBatch(pages: pages, rows: rows, columns: columns, textUnits: textUnits, finished: true))
    }

    func readPage(at start: PreviewPageStart, block: Int) throws -> [[PreviewCell]] {
        let reader = PreviewRecordReader(file: file, encoding: encoding, offset: start.offset)
        let startColumn = block * Self.blockColumns
        let columns = startColumn..<(startColumn + Self.blockColumns)
        var rows: [[PreviewCell]] = []
        rows.reserveCapacity(Self.pageRows)
        let syntax = mode.language.map(CodeSyntax.forLanguage)
        var ranges: [NSRange] = []
        var pageText = ""
        var textLength = 0
        for _ in 0..<Self.pageRows {
            try Task.checkCancellation()
            guard let record = try reader.next(mode: mode, columns: columns) else { break }
            if syntax != nil, let cell = record.cells.first {
                let length = cell.display.utf16.count
                ranges.append(NSRange(location: textLength, length: length))
                pageText += cell.display
                if record.lineEnded { pageText += "\n" }
                textLength += length + (record.lineEnded ? 1 : 0)
            }
            rows.append(record.cells)
        }
        if let syntax, ranges.count == rows.count {
            var state = start.syntaxState
            let spans = syntax.scan(pageText, continuing: &state).sorted { $0.range.location < $1.range.location }
            var first = 0
            for (index, range) in ranges.enumerated() {
                while first < spans.count, NSMaxRange(spans[first].range) <= range.location { first += 1 }
                var spanIndex = first
                while spanIndex < spans.count, spans[spanIndex].range.location < NSMaxRange(range) {
                    let span = spans[spanIndex]
                    let overlap = NSIntersectionRange(range, span.range)
                    if overlap.length > 0 {
                        rows[index][0].highlights.append(SyntaxSpan(
                            range: NSRange(location: overlap.location - range.location, length: overlap.length),
                            role: span.role))
                    }
                    spanIndex += 1
                }
            }
        }
        return rows
    }

    func textWidth(for units: Int) -> CGFloat {
        CGFloat(units * (encoding.unitBytes == 2 ? 15 : 8) + 20)
    }
}

// All readers use independent offsets on the same open file. pread does not change the descriptor's file position.
private final class PreviewFile: @unchecked Sendable {
    let size: UInt64
    private let descriptor: Int32

    init(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadUnknown)
        }
        self.descriptor = descriptor
        size = UInt64(info.st_size)
    }

    deinit { Darwin.close(descriptor) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        let length = Int(min(UInt64(count), size > offset ? size - offset : 0))
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let read = try data.withUnsafeMutableBytes { buffer in
            var count = 0
            while count < length {
                let result = pread(descriptor, buffer.baseAddress?.advanced(by: count), length - count, off_t(offset) + off_t(count))
                if result == 0 { break }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                count += result
            }
            return count
        }
        data.count = read
        return data
    }
}

private enum PreviewEncoding: Sendable {
    case utf8, utf16Little, utf16Big, gb18030

    private static let chinese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    ))

    var unitBytes: Int {
        switch self {
        case .utf16Little, .utf16Big: return 2
        case .utf8, .gb18030: return 1
        }
    }

    static func detect(_ bytes: Data, partial: Bool) -> (Self, UInt64)? {
        if bytes.starts(with: [0xff, 0xfe]) { return (.utf16Little, 2) }
        if bytes.starts(with: [0xfe, 0xff]) { return (.utf16Big, 2) }
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { return (.utf8, 3) }
        guard !bytes.contains(0) else { return nil }
        for trim in 0...(partial ? 3 : 0) where trim <= bytes.count {
            if String(data: bytes.dropLast(trim), encoding: .utf8) != nil { return (.utf8, 0) }
        }
        for trim in 0...(partial ? 3 : 0) where trim <= bytes.count {
            if String(data: bytes.dropLast(trim), encoding: chinese) != nil { return (.gb18030, 0) }
        }
        return nil
    }

    func decode(_ bytes: Data) -> String {
        switch self {
        case .utf8:
            return String(data: bytes, encoding: .utf8)
                ?? String(data: bytes, encoding: Self.chinese)
                ?? String(decoding: bytes, as: UTF8.self)
        case .utf16Little:
            return String(data: bytes, encoding: .utf16LittleEndian) ?? ""
        case .utf16Big:
            return String(data: bytes, encoding: .utf16BigEndian) ?? ""
        case .gb18030:
            return String(data: bytes, encoding: Self.chinese) ?? String(decoding: bytes, as: UTF8.self)
        }
    }
}

private final class PreviewRecordReader {
    private struct ByteBuffer {
        var data = Data()
        var position = 0
    }

    struct Record {
        let cells: [PreviewCell]
        let columns: Int
        let textUnits: Int
        var lineEnded = false
    }

    private enum FieldState { case start, plain, quoted, afterQuote }

    private let file: PreviewFile
    private let encoding: PreviewEncoding
    private var buffer = ByteBuffer()
    private var reachedEnd = false
    private(set) var offset: UInt64

    init(file: PreviewFile, encoding: PreviewEncoding, offset: UInt64) {
        self.file = file
        self.encoding = encoding
        self.offset = offset
    }

    func next(mode: PreviewPageMode, columns: Range<Int>?) throws -> Record? {
        switch mode {
        case .delimited(let separator): return try delimited(separator: separator, columns: columns)
        case .text: return try text(capture: columns?.contains(0) == true)
        }
    }

    private func peek() throws -> UInt16? {
        if buffer.position == buffer.data.count {
            guard !reachedEnd else { return nil }
            try Task.checkCancellation()
            buffer = ByteBuffer(data: try file.read(at: offset, count: 64 * 1024))
            reachedEnd = buffer.data.count < encoding.unitBytes
        }
        let index = buffer.position
        guard index + encoding.unitBytes <= buffer.data.count else { return nil }
        let first = UInt16(buffer.data[index])
        if encoding.unitBytes == 1 { return first }
        let second = UInt16(buffer.data[index + 1])
        return encoding == .utf16Little ? first | (second << 8) : (first << 8) | second
    }

    private func consume() {
        buffer.position += encoding.unitBytes
        offset += UInt64(encoding.unitBytes)
    }

    private func append(_ unit: UInt16, to field: inout Data) {
        if encoding == .utf16Big { field.append(UInt8(unit >> 8)) }
        field.append(UInt8(truncatingIfNeeded: unit))
        if encoding == .utf16Little { field.append(UInt8(unit >> 8)) }
    }

    private func swallowLF(after unit: UInt16) throws {
        if unit == 13, try peek() == 10 { consume() }
    }

    private func delimited(separator: UInt16, columns: Range<Int>?) throws -> Record? {
        let start = offset
        var state = FieldState.start
        var cells: [PreviewCell] = []
        var field = Data()
        var column = 0
        var capture = columns?.contains(column) == true

        while let unit = try peek() {
            consume()
            let newline = unit == 10 || unit == 13
            if state != .quoted, unit == separator || newline {
                if capture {
                    cells.append(PreviewCell(encoding.decode(field), singleLine: true))
                    field.removeAll(keepingCapacity: true)
                }
                column += 1
                if newline {
                    try swallowLF(after: unit)
                    return Record(cells: cells, columns: column, textUnits: 0)
                }
                state = .start
                capture = columns?.contains(column) == true
            } else if unit == 34, state == .start || state == .quoted {
                state = state == .start ? .quoted : .afterQuote
            } else {
                if capture { append(unit, to: &field) }
                if state == .afterQuote, unit == 34 { state = .quoted }
                else if state != .quoted { state = .plain }
            }
        }

        guard offset > start else { return nil }
        if capture { cells.append(PreviewCell(encoding.decode(field), singleLine: true)) }
        return Record(cells: cells, columns: column + 1, textUnits: 0)
    }

    private func text(capture: Bool) throws -> Record? {
        let start = offset
        var field = Data()
        var units = 0
        var tabExpansion = 0
        var lineEnded = false
        while let unit = try peek() {
            if unit == 10 || unit == 13 {
                consume()
                try swallowLF(after: unit)
                lineEnded = true
                break
            }
            // Fold enormous single lines into scrollable screen rows without splitting encoded scalars.
            if units >= 240 { break }
            consume()
            if capture { append(unit, to: &field) }
            units += 1
            if unit == 9 { tabExpansion += 3 }
            var remaining = continuationCount(for: unit)
            var consumed = 0
            while consumed < remaining, let next = try peek(), isContinuation(next) {
                consume()
                if capture { append(next, to: &field) }
                if encoding == .gb18030, consumed == 0, (48...57).contains(next) { remaining = 3 }
                consumed += 1
                units += 1
            }
        }
        guard offset > start else { return nil }
        let cells = capture ? [PreviewCell(encoding.decode(field), singleLine: false)] : []
        return Record(cells: cells, columns: 1, textUnits: units + tabExpansion, lineEnded: lineEnded)
    }

    private func continuationCount(for unit: UInt16) -> Int {
        switch encoding {
        case .utf8:
            switch unit {
            case 0xc2...0xdf: return 1
            case 0xe0...0xef: return 2
            case 0xf0...0xf4: return 3
            default: return 0
            }
        case .gb18030:
            return (0x81...0xfe).contains(unit) ? 1 : 0
        case .utf16Little, .utf16Big:
            return (0xd800...0xdbff).contains(unit) ? 1 : 0
        }
    }

    private func isContinuation(_ unit: UInt16) -> Bool {
        switch encoding {
        case .utf8: return (0x80...0xbf).contains(unit)
        case .gb18030: return (0x30...0x39).contains(unit) || (0x40...0xfe).contains(unit)
        case .utf16Little, .utf16Big: return (0xdc00...0xdfff).contains(unit)
        }
    }
}
