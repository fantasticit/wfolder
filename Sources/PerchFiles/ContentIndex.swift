import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

struct ContentIndex {
    struct Coverage: Sendable {
        let files: Int
        let sections: Int
        let partial: Int
    }

    struct Match: Identifiable, Equatable, Sendable {
        let id: String
        let url: URL
        let page: Int
        let label: String
        let excerpt: String
    }

    let root: URL
    let storage: ProfessionalStorage
    var includesDescendants = true
    var showHidden = false

    private var location: URL {
        let scope = root.standardizedFileURL.path + (includesDescendants ? "" : "\0current") + (showHidden ? "\0hidden" : "")
        let key = VerifiedFile.hex(SHA256.hash(data: Data(scope.utf8)))
        return storage.directory.appendingPathComponent("index-" + key + ".sqlite")
    }

    private func open(create: Bool) throws -> SQLiteDatabase? {
        if !create && !FileManager.default.fileExists(atPath: location.path) { return nil }
        if create {
            try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        return try SQLiteDatabase(url: location, writable: create)
    }

    func rebuild(progress: TransferMeter) throws -> Coverage {
        guard let db = try open(create: true) else { throw CocoaError(.fileWriteUnknown) }
        let scope = try TransferFiles.Destination(root).physical
        try db.execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, stamp TEXT, partial INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sections (path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
                part INTEGER NOT NULL, page INTEGER NOT NULL, label TEXT NOT NULL, text TEXT NOT NULL,
                folded TEXT NOT NULL, PRIMARY KEY(path, part));
            CREATE TABLE IF NOT EXISTS scan (unavailable INTEGER);
            BEGIN IMMEDIATE;
            """)
        do {
            let snapshot = try db.prepare("SELECT path, stamp, partial FROM files;")
            let decoder = JSONDecoder()
            var old = [String: FileStamp]()
            var stale: Set<String> = []
            while try snapshot.next() {
                let path = snapshot.string(0)
                stale.insert(path)
                if snapshot.integer(2) == 0, let data = Data(base64Encoded: snapshot.string(1)),
                   let stamp = try? decoder.decode(FileStamp.self, from: data) { old[path] = stamp }
            }

            let remove = try db.prepare("DELETE FROM files WHERE path = ?;")
            let insert = try db.prepare("INSERT INTO files VALUES(?, ?, ?);")
            let part = try db.prepare("INSERT INTO sections VALUES(?, ?, ?, ?, ?, ?);")
            let encoder = JSONEncoder()
            var scanned: Int64 = 0
            var rootError: Error?
            var unavailable = 0
            let location = scope.standardizedFileURL.path
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            if !includesDescendants { options.insert(.skipsSubdirectoryDescendants) }
            guard let urls = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: [.isPackageKey],
                options: options, errorHandler: { url, error in
                    if url.standardizedFileURL.path == location { rootError = error; return false }
                    unavailable += 1
                    return !Task.isCancelled
                }) else { throw CocoaError(.fileReadNoSuchFile) }
            for case let url as URL in urls {
                try Task.checkCancellation()
                guard ContentText.supports(url), let stamp = FileStamp(url), stamp.regular else { continue }
                let path = url.path
                stale.remove(path)
                scanned += 1
                progress.update(scanned)
                if old[path] == stamp { continue }
                let output: ContentText.Output
                do { output = try ContentText.extract(url, stamp: stamp) }
                catch is CancellationError { throw CancellationError() }
                catch { output = .init(parts: [], partial: true) }
                guard FileStamp(url) == stamp else { stale.insert(path); continue }
                try remove.bind(path, to: 1)
                try remove.run()
                try insert.bind(path, to: 1)
                try insert.bind(encoder.encode(stamp).base64EncodedString(), to: 2)
                try insert.bind(output.partial ? 1 : 0, to: 3)
                try insert.run()
                for (index, entry) in output.parts.enumerated() where !entry.text.isEmpty {
                    try part.bind(path, to: 1)
                    try part.bind(index, to: 2)
                    try part.bind(entry.page, to: 3)
                    try part.bind(entry.label, to: 4)
                    try part.bind(entry.text, to: 5)
                    try part.bind(Self.fold(entry.text), to: 6)
                    try part.run()
                }
            }
            if let rootError { throw rootError }
            for path in stale {
                try remove.bind(path, to: 1)
                try remove.run()
            }
            try db.execute("DELETE FROM scan;")
            let count = try db.prepare("INSERT INTO scan VALUES (?);")
            try count.bind(unavailable, to: 1)
            try count.run()
            try Task.checkCancellation()
            try db.execute("COMMIT;")
            return try coverage(db)
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    func delete() throws {
        for path in [location.path, location.path + "-wal", location.path + "-shm"] {
            do { try FileManager.default.removeItem(atPath: path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }

    func coverage() throws -> Coverage? {
        guard let db = try open(create: false) else { return nil }
        return try coverage(db)
    }

    private func coverage(_ db: SQLiteDatabase) throws -> Coverage {
        let statement = try db.prepare("""
            SELECT COUNT(*), (SELECT COUNT(*) FROM sections),
                COALESCE(SUM(partial), 0) + COALESCE((SELECT unavailable FROM scan), 0) FROM files;
            """)
        guard try statement.next() else { return Coverage(files: 0, sections: 0, partial: 0) }
        return Coverage(files: statement.integer(0), sections: statement.integer(1), partial: statement.integer(2))
    }

    func search(_ query: String, limit: Int = 200, includeFile: (URL) -> Bool = { _ in true }) throws -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let db = try open(create: false) else { return [] }
        let statement = try db.prepare("""
            SELECT sections.path, part, page, label, text, files.stamp
            FROM sections JOIN files ON files.path = sections.path
            WHERE instr(folded, ?) > 0 ORDER BY sections.path, part;
            """)
        try statement.bind(Self.fold(query), to: 1)
        var results: [Match] = []
        let decoder = JSONDecoder()
        var previousPath: String?
        var includesCurrentFile = false
        while results.count < limit, try statement.next() {
            try Task.checkCancellation()
            let path = statement.string(0)
            let url = URL(fileURLWithPath: path)
            if path != previousPath {
                previousPath = path
                if let data = Data(base64Encoded: statement.string(5)),
                   let stamp = try? decoder.decode(FileStamp.self, from: data), FileStamp(url) == stamp {
                    includesCurrentFile = includeFile(url)
                } else { includesCurrentFile = false }
            }
            guard includesCurrentFile else { continue }
            let text = statement.string(4)
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            let start = found.map { text.index($0.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
            let excerpt = text[start...].prefix(180).replacingOccurrences(of: "\n", with: " ")
            results.append(Match(id: url.path + "#\(statement.integer(1))", url: url, page: statement.integer(2),
                                 label: statement.string(3), excerpt: excerpt))
        }
        return results
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

enum ContentText {
    struct Part: Sendable {
        let page: Int
        let label: String
        let text: String
    }

    struct Output: Sendable {
        let parts: [Part]
        var partial = false
    }

    private static let textLimit = 4 * 1024 * 1024
    private static let pageLimit = 250
    private static let officeExtensions = ["docx", "pptx", "xlsx"]
    private static let extras = ["md", "markdown", "csv", "tsv", "json", "yaml", "yml", "toml", "rs", "go", "kt",
                                  "cs", "tsx", "ts", "jsx", "js", "swift", "h", "cpp", "c", "py", "sql", "sh"]

    static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        return ext == "pdf" || officeExtensions.contains(ext) || extras.contains(ext) ||
            type?.conforms(to: .text) == true || type?.conforms(to: .image) == true
    }

    static func extract(_ url: URL, stamp: FileStamp) throws -> Output {
        let attributes = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if attributes?.isUbiquitousItem == true, attributes?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return Output(parts: [], partial: true)
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return try pdf(url) }
        if officeExtensions.contains(ext) { return try office(url, ext: ext) }
        if UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            guard let image = VersionRaster.raster(url, limit: 2000) else { throw CocoaError(.fileReadCorruptFile) }
            return Output(parts: [Part(page: -1, label: "OCR", text: try visuallyRead(image))])
        }
        let input = try VerifiedFile.open(url, stamp: stamp)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: textLimit) ?? Data()
        let utf16 = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
        guard utf16 || !bytes.contains(0) else { return Output(parts: [], partial: true) }
        let text = utf16 ? String(data: bytes, encoding: .utf16) ?? "" : String(decoding: bytes, as: UTF8.self)
        return Output(parts: chunks(text, label: "正文"), partial: stamp.bytes > Int64(bytes.count))
    }

    private static func pdf(_ url: URL) throws -> Output {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { throw CocoaError(.fileReadCorruptFile) }
        var parts: [Part] = []
        var partial = doc.pageCount > pageLimit
        for page in 0..<min(doc.pageCount, pageLimit) {
            try Task.checkCancellation()
            guard let item = doc.page(at: page) else { partial = true; continue }
            let visible = item.string ?? ""
            var text = visible
            if visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let image = VersionRaster.raster(item.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)) {
                do { text = try visuallyRead(image) }
                catch { partial = true }
            }
            if text.count > 75_000 { partial = true }
            parts.append(Part(page: page + 1, label: "第 \(page + 1) 页", text: String(text.prefix(75_000))))
        }
        return Output(parts: parts, partial: partial)
    }

    private static func visuallyRead(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // This revision supports both languages without the newer model's initial ANE compilation.
        request.revision = VNRecognizeTextRequestRevision2
        let available = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "en-US"].filter(available.contains)
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func office(_ url: URL, ext: String) throws -> Output {
        let container = try ZipContents(archive: url)
        let selected: [(String, String)]
        switch ext {
        case "docx": selected = [("word/document.xml", "文档正文")]
        case "pptx":
            selected = (container.children["ppt/slides"] ?? []).filter {
                $0.path.range(of: #"/slide[0-9]+\.xml$"#, options: .regularExpression) != nil
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map {
                ($0.path, $0.name.replacingOccurrences(of: "slide", with: "幻灯片 ").replacingOccurrences(of: ".xml", with: ""))
            }
        default:
            let book = try XLSXWorkbook.read(url)
            selected = book.sheets.map { ($0.path, $0.name) } + (book.sharedStrings.map { [($0, "工作簿共享文字")] } ?? [])
        }
        let temporary = try XLSXTemporaryDirectory()
        var mapping = [String: URL]()
        var labels = [String: String]()
        var partial = selected.count > pageLimit
        let sizes = Dictionary(container.children.values.flatMap { $0 }.compactMap { member in
            member.size.map { (member.path, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var budget = 32 * 1024 * 1024 as Int64
        for (index, pair) in selected.prefix(pageLimit).enumerated() {
            guard let bytes = sizes[pair.0], bytes >= 0, bytes <= Int64(textLimit), bytes <= budget else {
                partial = true
                continue
            }
            budget -= bytes
            mapping[pair.0] = temporary.file("\(index).xml")
            labels[pair.0] = pair.1
        }
        if !mapping.isEmpty { try ZipContents.copyParts(mapping, from: url, maxPartBytes: Int64(textLimit)) }
        var parts: [Part] = []
        for (path, _) in selected {
            try Task.checkCancellation()
            guard let member = mapping[path], let label = labels[path] else { continue }
            let reader = OfficeTextReader()
            let parser = XMLParser(data: try Data(contentsOf: member, options: .mappedIfSafe))
            parser.shouldResolveExternalEntities = false
            parser.delegate = reader
            if parser.parse() { parts += chunks(reader.text, label: label) }
            else { partial = true }
        }
        return Output(parts: parts, partial: partial)
    }

    private static func chunks(_ text: String, label: String) -> [Part] {
        var result: [Part] = []
        var head = text.startIndex
        while head < text.endIndex {
            let end = text.index(head, offsetBy: 32_000, limitedBy: text.endIndex) ?? text.endIndex
            result.append(Part(page: -1, label: label, text: String(text[head..<end])))
            if end == text.endIndex { break }
            head = text.index(end, offsetBy: -240)
        }
        return result
    }

    private final class OfficeTextReader: NSObject, XMLParserDelegate {
        var text = ""
        private var collecting = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            collecting = ["t", "v"].contains(name.split(separator: ":").last.map(String.init) ?? "")
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { text += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if collecting { text += "\n"; collecting = false }
        }
    }
}
