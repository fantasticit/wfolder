import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Constructed off the main thread, then used only by the main-thread PDF view.
struct PreparedPDF: @unchecked Sendable {
    let document: PDFDocument
}

enum PreviewData: Sendable {
    case text(String, monospaced: Bool)
    case paged(PagedPreviewSource)
    case image(CGImage)
    case pdf(PreparedPDF)
    case media
    case quickLook

    nonisolated static func load(_ entry: FileEntry) -> Self {
        guard !Task.isCancelled else { return .quickLook }
        let url = entry.url
        let file = url.resolvingSymlinksInPath()
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .quickLook
        }
        guard !Task.isCancelled else { return .quickLook }
        let ext = url.pathExtension.lowercased()
        let type = entry.contentType

        if ext == "pdf" || type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { return .quickLook }
            return .pdf(PreparedPDF(document: document))
        }
        if type?.conforms(to: .audiovisualContent) == true
            || ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aac", "flac"].contains(ext) { return .media }
        if [
            "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "rtfd",
            "svg", "gif"
        ].contains(ext) { return .quickLook }

        if type?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 2200,
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) { return .image(thumbnail) }

        let sourceFormats = [
            "csv", "tsv", "txt", "md", "markdown", "json", "jsonl", "yaml", "yml", "xml", "html", "htm",
            "log", "toml", "ini", "swift", "py", "js", "ts", "css", "sh", "sql", "conf", "rs", "go", "java"
        ]
        guard sourceFormats.contains(ext) || type?.conforms(to: .text) == true else { return .quickLook }
        let monospaced = ext != "txt"
        let mode: PreviewPageMode = ext == "csv" || ext == "tsv"
            ? .delimited(separator: ext == "csv" ? 44 : 9)
            : .text(monospaced: monospaced)
        do {
            guard let source = try PagedPreviewSource(url: url, mode: mode) else { return .quickLook }
            guard let text = try source.smallText() else { return .paged(source) }
            if ext == "json",
               let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
               let formatted = try? JSONSerialization.data(withJSONObject: json,
                   options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
               formatted.count <= 512 * 1024,
               let readable = String(data: formatted, encoding: .utf8), hasShortLines(readable) {
                return .text(readable, monospaced: true)
            }
            return hasShortLines(text) ? .text(text, monospaced: monospaced) : .paged(source)
        } catch {
            return .quickLook
        }
    }

    private nonisolated static func hasShortLines(_ text: String) -> Bool {
        var length = 0
        for byte in text.utf8 {
            length = byte == 10 || byte == 13 ? 0 : length + 1
            if length > 4096 { return false }
        }
        return true
    }
}
