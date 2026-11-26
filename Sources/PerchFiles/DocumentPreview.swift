import CoreText
import SwiftUI

// Imported off the main thread and consumed by the main-thread text view.
struct PreparedWord: @unchecked Sendable {
    let content: NSAttributedString

    nonisolated init?(url: URL) {
        let file = url.resolvingSymlinksInPath()
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16 * 1024 * 1024,
              let content = try? NSAttributedString(
                url: file,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
              ) else { return nil }
        self.content = content
    }
}

struct WordPreview: NSViewRepresentable {
    let document: NSAttributedString

    final class Coordinator {
        var document: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 renders Office-imported tables and embedded attachments.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.appearance = NSAppearance(named: .aqua)
        textView.setAccessibilityLabel("Word 文档内容")
        let scroll = TextPreview.makeScrollView(for: textView)
        scroll.backgroundColor = .white
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.document !== document,
              let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.document = document
        view.textStorage?.setAttributedString(document)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

// CGFont is immutable. The preview builds its display fonts on the main thread.
struct FontSpecimen: @unchecked Sendable {
    let font: CGFont
    let name: String
    let referenceName: String
    let sample: String

    nonisolated init?(url: URL) {
        guard let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider) else { return nil }
        let face = CTFontCreateWithGraphicsFont(font, 24, nil, nil)
        self.font = font
        name = CTFontCopyDisplayName(face) as String
        referenceName = CTFontCopyPostScriptName(face) as String
        sample = Self.sampleText(for: CTFontCopyCharacterSet(face) as CharacterSet)
    }

    private nonisolated static func sampleText(for glyphs: CharacterSet) -> String {
        let candidates = [
            "The quick brown fox jumps over the lazy dog.",
            "天地玄黄，宇宙洪荒。",
            "これはフォントの見本です。",
            "다람쥐 헌 쳇바퀴에 타고파.",
        ]
        var samples = candidates.filter { sample in
            sample.unicodeScalars.allSatisfy { glyphs.contains($0) || CharacterSet.whitespaces.contains($0) }
        }
        if !samples.isEmpty {
            let digits = "0123456789 !? @#$% & + −".unicodeScalars.filter {
                glyphs.contains($0) || CharacterSet.whitespaces.contains($0)
            }
            samples.append(String(String.UnicodeScalarView(digits)))
            return samples.joined(separator: "\n")
        }

        var sample = String.UnicodeScalarView()
        let invisible = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        for plane in 0...16 where glyphs.hasMember(inPlane: UInt8(plane)) {
            let start = plane << 16
            for codePoint in start..<(start + 0x10000) {
                guard let scalar = Unicode.Scalar(codePoint),
                      glyphs.contains(scalar), !invisible.contains(scalar) else { continue }
                sample.append(scalar)
                if sample.count == 48 { return String(sample) }
            }
        }
        return String(sample)
    }
}

struct FontPreview: View {
    let specimen: FontSpecimen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(specimen.name).font(.headline)
                    if specimen.referenceName != specimen.name {
                        Text(specimen.referenceName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if specimen.sample.isEmpty {
                    Text("没有可显示的字符").foregroundStyle(.secondary)
                } else {
                    Divider()
                    ForEach([32, 20, 14], id: \.self) { size in
                        Text(specimen.sample)
                            .font(Font(CTFontCreateWithGraphicsFont(specimen.font, CGFloat(size), nil, nil)))
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
