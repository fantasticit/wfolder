import AppKit
import UniformTypeIdentifiers

extension FileEntry {
    var glyph: (symbol: String, tint: NSColor) {
        if isFolder { return ("folder.fill", .controlAccentColor) }
        let extensionName = url.pathExtension.lowercased()
        if ["xlsx", "xls", "numbers", "csv", "tsv"].contains(extensionName) { return ("tablecells", .systemGreen) }
        if ["pptx", "ppt", "key"].contains(extensionName) { return ("play.rectangle", .systemOrange) }
        guard let contentType else { return ("document", .secondaryLabelColor) }
        if contentType.conforms(to: .image) { return ("photo", .systemIndigo) }
        if contentType.conforms(to: .pdf) { return ("doc.richtext", .systemRed) }
        if contentType.conforms(to: .movie) { return ("film", .systemPurple) }
        if contentType.conforms(to: .audio) { return ("waveform", .systemPink) }
        if contentType.conforms(to: .archive) { return ("archivebox", .systemBrown) }
        if contentType.conforms(to: .application) { return ("app", .systemOrange) }
        if contentType.conforms(to: .text) { return ("document", .systemBlue) }
        return ("document", .secondaryLabelColor)
    }
}
