import AppKit
import UniformTypeIdentifiers

private let documentIconTint = NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        return NSColor(srgbRed: 0.65, green: 0.80, blue: 1, alpha: 1)
    }
    return NSColor(srgbRed: 0.20, green: 0.33, blue: 0.50, alpha: 1)
}

extension FileEntry {
    var isMarkdown: Bool {
        guard !isFolder else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || contentType?.identifier == "net.daringfireball.markdown"
    }

    var glyph: (symbol: String, tint: NSColor) {
        if isFolder { return ("folder", .secondaryLabelColor) }
        if let sourceLanguage { return (sourceLanguage.iconSymbol, documentIconTint) }
        if isMarkdown { return ("doc.text", documentIconTint) }
        if isApplication { return ("app", .secondaryLabelColor) }
        if let mediaKind { return (mediaKind.symbol, .secondaryLabelColor) }
        if contentType?.conforms(to: .image) == true { return ("photo", .secondaryLabelColor) }
        if contentType?.conforms(to: .archive) == true { return ("archivebox", .secondaryLabelColor) }
        return ("doc", .secondaryLabelColor)
    }

    var iconAccessibilityLabel: String {
        if let sourceLanguage { return "\(sourceLanguage.rawValue) 文件图标" }
        if isMarkdown { return "Markdown 文件图标" }
        if isFolder { return "文件夹图标" }
        if isApplication { return "应用程序图标" }
        if let mediaKind { return mediaKind == .audio ? "音频图标" : "视频图标" }
        return "文件图标"
    }

    @MainActor func placeholderIcon(size: CGFloat, detailed: Bool = false) -> NSImage? {
        if let sourceLanguage {
            return MarkedDocumentIcons.image(mark: sourceLanguage.iconMark, symbol: sourceLanguage.iconSymbol,
                                             size: size, detailed: detailed)
        }
        if isMarkdown {
            return MarkedDocumentIcons.image(mark: "MD", symbol: "text.alignleft", size: size, detailed: detailed)
        }
        return NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }
}

private extension SourceLanguage {
    var iconSymbol: String {
        switch self {
        case .sql: return "cylinder"
        case .shell, .powershell: return "terminal"
        case .json: return "curlybraces"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var iconMark: String {
        switch self {
        case .typescript: return "TS"
        case .javascript: return "JS"
        case .python: return "PY"
        case .ruby: return "RB"
        case .rust: return "RS"
        case .c: return "C"
        case .csharp: return "C#"
        case .kotlin: return "KT"
        case .shell: return "SH"
        case .powershell: return "PS"
        case .docker: return "DOCK"
        case .make: return "MAKE"
        default: return rawValue.uppercased()
        }
    }
}

@MainActor
private enum MarkedDocumentIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(mark: String, symbol systemName: String, size: CGFloat, detailed: Bool) -> NSImage {
        let key = "\(mark):\(systemName):\(size):\(detailed)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let symbol = detailed ? NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.25, weight: .medium)) : nil
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { bounds in
            let pageWidth = size * 0.77
            let pageHeight = size * 0.91
            let page = NSRect(x: (bounds.width - pageWidth) / 2, y: (bounds.height - pageHeight) / 2,
                              width: pageWidth, height: pageHeight)
            let fold = size * 0.20
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: page.minX, y: page.minY))
            outline.line(to: NSPoint(x: page.maxX - fold, y: page.minY))
            outline.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
            outline.line(to: NSPoint(x: page.maxX, y: page.maxY))
            outline.line(to: NSPoint(x: page.minX, y: page.maxY))
            outline.close()
            NSColor.black.withAlphaComponent(0.12).setFill()
            outline.fill()

            outline.move(to: NSPoint(x: page.maxX - fold, y: page.minY))
            outline.line(to: NSPoint(x: page.maxX - fold, y: page.minY + fold))
            outline.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
            outline.lineJoinStyle = .round
            outline.lineWidth = max(0.8, size * 0.024)
            NSColor.black.withAlphaComponent(0.78).setStroke()
            outline.stroke()

            if let symbol {
                symbol.draw(in: NSRect(x: page.midX - symbol.size.width / 2, y: page.midY - symbol.size.height * 0.68,
                                       width: symbol.size.width, height: symbol.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let fontSize = detailed ? size * 0.18 : min(size * 0.36, pageWidth / CGFloat(mark.count) * 1.15)
            let text = NSAttributedString(string: mark, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.black
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: page.midX - textSize.width / 2,
                                  y: page.midY + (detailed ? size * 0.13 : (fold - textSize.height) / 2)))
            return true
        }
        image.isTemplate = true
        cache.setObject(image, forKey: key)
        return image
    }
}
