import AppKit

enum SyntaxColors {
    static func attributed(_ text: String, spans: [SyntaxSpan], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for span in spans {
            result.addAttribute(.foregroundColor, value: color(for: span.role), range: span.range)
        }
        return result
    }

    private static func color(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword: return .systemPurple
        case .string: return .systemOrange
        case .comment: return .secondaryLabelColor
        case .number: return .systemTeal
        case .literal: return .systemPink
        case .tag: return .systemBlue
        }
    }
}
