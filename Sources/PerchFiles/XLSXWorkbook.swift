import Foundation

struct XLSXWorkbook: Sendable {
    struct Sheet: Identifiable, Hashable, Sendable {
        let name: String
        let path: String
        var id: String { path }
    }

    let id = UUID()
    let url: URL
    let sheets: [Sheet]
    let sharedStrings: String?

    static func read(_ url: URL) throws -> Self {
        let scratch = try XLSXTemporaryDirectory()
        let rootRelationships = scratch.file("root.xml")
        try ZipContents.copyParts(["_rels/.rels": rootRelationships], from: url, maxPartBytes: 8 << 20)
        let root = try XLSXMetadata.read(rootRelationships)
        guard let book = root.relationships.first(where: { $0.type == "officeDocument" }),
              let bookPath = partPath(book.target, relativeTo: "") else { throw XLSXError.invalid }

        let name = (bookPath as NSString).lastPathComponent
        let parent = (bookPath as NSString).deletingLastPathComponent
        let relationshipsPath = [parent, "_rels", name + ".rels"].filter { !$0.isEmpty }.joined(separator: "/")
        let bookFile = scratch.file("workbook.xml")
        let relationshipsFile = scratch.file("workbook-relations.xml")
        try ZipContents.copyParts([bookPath: bookFile, relationshipsPath: relationshipsFile],
                                  from: url, maxPartBytes: 8 << 20)
        let meta = try XLSXMetadata.read(bookFile)
        let relations = try XLSXMetadata.read(relationshipsFile).relationships
        let targets = Dictionary(relations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var knownPaths = Set<String>()
        let sheets = meta.sheets.compactMap { name, id -> Sheet? in
            guard let relation = targets[id], relation.type == "worksheet",
                  let path = partPath(relation.target, relativeTo: parent),
                  knownPaths.insert(path).inserted else { return nil }
            return Sheet(name: name, path: path)
        }
        let shared = relations.first { $0.type == "sharedStrings" }
            .flatMap { partPath($0.target, relativeTo: parent) }
        return Self(url: url, sheets: sheets, sharedStrings: shared)
    }

    private static func partPath(_ target: String, relativeTo parent: String) -> String? {
        guard let path = target.removingPercentEncoding, !path.isEmpty,
              !path.contains("\\"), !path.contains(":"), !path.utf8.contains(0) else { return nil }
        var components = path.hasPrefix("/") ? [] : parent.split(separator: "/")
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}

enum XLSXError: LocalizedError {
    case invalid

    var errorDescription: String? { "无法读取工作簿或工作表内容。" }
}

final class XLSXTemporaryDirectory: Sendable {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wfolder-xlsx-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

class XLSXXMLReader: NSObject, XMLParserDelegate {
    private(set) var failure: Error?

    func parse(_ url: URL) throws {
        guard let stream = InputStream(url: url) else { throw XLSXError.invalid }
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let valid = parser.parse()
        if let failure { throw failure }
        try Task.checkCancellation()
        guard valid else { throw XLSXError.invalid }
    }

    func abort(_ parser: XMLParser, because error: Error) {
        failure = error
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        abort(parser, because: XLSXError.invalid)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        abort(parser, because: XLSXError.invalid)
    }

    func localName(_ name: String) -> Substring { name.split(separator: ":").last ?? "" }
}

private final class XLSXMetadata: XLSXXMLReader {
    struct Relationship {
        let id: String
        let type: String
        let target: String
    }

    var sheets: [(String, String)] = []
    var relationships: [Relationship] = []

    static func read(_ url: URL) throws -> XLSXMetadata {
        let metadata = XLSXMetadata()
        try metadata.parse(url)
        return metadata
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { abort(parser, because: CancellationError()); return }
        switch localName(elementName) {
        case "sheet":
            if let name = attributes["name"], let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value {
                sheets.append((name, id))
            }
        case "Relationship":
            if attributes["TargetMode"]?.lowercased() != "external", let id = attributes["Id"],
               let type = attributes["Type"]?.split(separator: "/").last, let target = attributes["Target"] {
                relationships.append(Relationship(id: id, type: String(type), target: target))
            }
        default: break
        }
    }
}
