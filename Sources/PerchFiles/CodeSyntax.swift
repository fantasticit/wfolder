import Foundation

enum SyntaxRole: Sendable {
    case keyword, string, comment, number, literal, tag
}

struct SyntaxSpan: Sendable {
    let range: NSRange
    let role: SyntaxRole
}

struct SyntaxDelimiter: Sendable {
    let start: String
    let end: String?
    let role: SyntaxRole
    var multiline = false
    var escaped = false

    static func line(_ prefix: String) -> Self { Self(start: prefix, end: nil, role: .comment) }
    static func block(_ start: String, _ end: String) -> Self {
        Self(start: start, end: end, role: .comment, multiline: true)
    }
    static func quote(_ token: String, multiline: Bool = false) -> Self {
        Self(start: token, end: token, role: .string, multiline: multiline, escaped: true)
    }
}

struct CodeSyntax: Sendable {
    private static let grammars = Dictionary(uniqueKeysWithValues: SourceLanguage.allCases.map { ($0, Self($0)) })
    private static let wordsAndNumbers = try! NSRegularExpression(pattern:
        #"(?<number>(?<![\p{L}\p{N}_$])(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?))|(?<word>[@$]?[\p{L}_][\p{L}\p{N}_$]*)"#)
    private static let tags = try! NSRegularExpression(pattern: #"</?[\p{L}_][\p{L}\p{N}_.:-]*|/?>|<![A-Z]+"#)
    private static let keys = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_-])[\p{L}_-][\p{L}\p{N}_-]*(?=[ \t]*[:=])"#)

    private let delimiters: [String: SyntaxDelimiter]
    private let opening: NSRegularExpression
    private let keywords: Set<String>
    private let ignoresCase: Bool
    private let markup: Bool
    private let colorsKeys: Bool
    private static let literals: Set<String> = ["true", "false", "null", "nil", "undefined", "True", "False", "None"]

    static func forLanguage(_ language: SourceLanguage) -> Self { grammars[language]! }

    private init(_ language: SourceLanguage) {
        let quotes: [SyntaxDelimiter] = [.quote("\""), .quote("'")]
        let c: [SyntaxDelimiter] = [.line("//"), .block("/*", "*/")] + quotes
        let hash: [SyntaxDelimiter] = [.line("#")] + quotes
        let lexical: [SyntaxDelimiter]
        let wordList: String

        switch language {
        case .sql:
            lexical = [.line("--"), .block("/*", "*/"), .quote("'", multiline: true), .quote("\""),
                       .quote("\u{60}"), .quote("$$", multiline: true)]
            wordList = "select from where join inner left right full outer cross lateral on as and or not in is exists between like ilike group by having order asc desc limit offset fetch distinct insert into values update set delete returning create alter drop truncate table view materialized index schema database function procedure trigger default primary foreign key references constraint unique check over partition union all intersect except case when then else end begin commit rollback with recursive do conflict comment grant revoke explain analyze cascade sequence use int integer bigint varchar text boolean timestamp date numeric json jsonb"
        case .typescript, .javascript:
            lexical = c + [.quote("\u{60}", multiline: true)]
            wordList = "import export from as default async await const let var new class extends static super this public protected private abstract readonly interface implements type satisfies keyof infer namespace enum declare module typeof instanceof if else switch case break continue for of in while do return throw try catch finally yield function get set delete void number string boolean unknown never any object symbol bigint"
        case .swift:
            lexical = c + [.quote("\"\"\"", multiline: true)]
            wordList = "import class struct enum protocol extension actor associatedtype typealias public private fileprivate internal open package let var func init deinit static final mutating nonmutating override convenience required weak unowned inout guard if else switch case default for in while repeat break continue fallthrough return throw throws rethrows try do catch async await defer where some any self Self super"
        case .python:
            lexical = hash + [.quote("\"\"\"", multiline: true), .quote("'''", multiline: true)]
            wordList = "import from as def class async await if elif else match case for while in is not and or assert break continue return yield print lambda with try except finally raise pass del global nonlocal"
        case .ruby:
            lexical = hash
            wordList = "require module class def end do then if elsif else unless case when while until for in break next redo retry begin rescue ensure raise return yield self super attr_reader attr_writer attr_accessor"
        case .rust:
            lexical = [.line("//"), .block("/*", "*/"), .quote("\"")]
            wordList = "use mod crate pub struct enum trait impl type const let mut fn async await match if else for in loop while break continue return self Self super where move ref dyn unsafe extern as"
        case .go:
            lexical = c + [.quote("\u{60}", multiline: true)]
            wordList = "package import func struct interface map type var const defer go select chan if else switch case default for range break continue return fallthrough goto"
        case .c, .cpp:
            lexical = c
            wordList = "include define pragma ifdef ifndef endif struct union enum typedef using namespace template typename class public protected private virtual override friend constexpr const static extern volatile auto inline void bool char int long float double unsigned signed sizeof if else switch case default for while do goto break continue return try catch throw nullptr new delete"
        case .csharp, .java, .kotlin:
            lexical = c + [.quote("\"\"\"", multiline: true)]
            wordList = "package import using namespace public protected private internal static final abstract override virtual sealed record interface class struct enum annotation object companion data fun val var void bool boolean int long float double char byte string String extends implements this super new if else switch case when default for foreach in while do break continue return throw throws try catch finally async await suspend yield readonly get set"
        case .php:
            lexical = c + [.line("#")]
            wordList = "namespace use require include function class interface extends implements static public private protected readonly foreach as if elseif else switch case default while for break continue return throw try catch new echo print match fn"
        case .lua:
            lexical = [.block("--[[", "]]"), .line("--")] + quotes
            wordList = "local function end require do if then elseif else for in while repeat until return break and or not"
        case .shell, .powershell:
            lexical = hash
            wordList = "if then elif else fi for in do done while until case esac function return export local unset set source echo printf read test exit trap switch param foreach begin process end throw try catch finally"
        case .docker:
            lexical = hash
            wordList = "from as run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell"
        case .make:
            lexical = hash
            wordList = "include define endef ifdef ifndef ifeq ifneq else endif export unexport override private"
        case .html, .xml:
            lexical = [.block("<!--", "-->")] + quotes
            wordList = ""
        case .css:
            lexical = [.block("/*", "*/")] + quotes
            wordList = "@import @media @supports @font-face @keyframes @layer @container important inherit initial unset var calc rgb rgba"
        case .json:
            lexical = [.line("//"), .block("/*", "*/"), .quote("\"")]
            wordList = ""
        case .yaml, .toml:
            lexical = hash + (language == .toml ? [.quote("\"\"\"", multiline: true), .quote("'''", multiline: true)] : [])
            wordList = ""
        case .ini:
            lexical = [.line(";")] + hash
            wordList = ""
        }
        delimiters = Dictionary(uniqueKeysWithValues: lexical.map { ($0.start, $0) })
        let starts = lexical.map(\.start).sorted { $0.utf16.count > $1.utf16.count }
        opening = try! NSRegularExpression(pattern: starts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))
        keywords = Set(wordList.split(separator: " ").map(String.init))
        ignoresCase = [.sql, .docker, .powershell, .ini].contains(language)
        markup = language == .html || language == .xml
        colorsKeys = [.yaml, .toml, .ini, .css].contains(language)
    }

    // NSTextStorage and the paged table both use UTF-16 ranges.
    func scan(_ text: String, continuing state: inout SyntaxDelimiter?, highlights: Bool = true) -> [SyntaxSpan] {
        let input = text as NSString
        let end = input.length
        var cursor = 0
        var spans: [SyntaxSpan] = []
        while cursor < end, !Task.isCancelled {
            if let delimiter = state {
                let start = cursor
                if let boundary = closing(delimiter, input: input, from: cursor) {
                    cursor = NSMaxRange(boundary)
                    state = nil
                } else {
                    cursor = end
                }
                if highlights, cursor > start {
                    spans.append(SyntaxSpan(range: NSRange(location: start, length: cursor - start), role: delimiter.role))
                }
            } else {
                let remainder = NSRange(location: cursor, length: end - cursor)
                let next = opening.firstMatch(in: text, range: remainder)
                if highlights {
                    let plain = NSRange(location: cursor, length: (next?.range.location ?? end) - cursor)
                    appendWords(in: text, input: input, range: plain, to: &spans)
                }
                guard let next, let delimiter = delimiters[input.substring(with: next.range)] else { break }
                cursor = NSMaxRange(next.range)
                state = delimiter
                if highlights { spans.append(SyntaxSpan(range: next.range, role: delimiter.role)) }
            }
        }
        return spans
    }

    private func closing(_ delimiter: SyntaxDelimiter, input: NSString, from start: Int) -> NSRange? {
        let range = NSRange(location: start, length: input.length - start)
        if let end = delimiter.end {
            let lineEnd = delimiter.multiline ? NSNotFound : input.rangeOfCharacter(from: .newlines, range: range).location
            let limit = lineEnd == NSNotFound ? input.length : lineEnd
            var index = start
            while index < limit {
                let match = input.range(of: end, options: .literal, range: NSRange(location: index, length: limit - index))
                guard match.location != NSNotFound else { break }
                if !delimiter.escaped || !isEscaped(input, at: match.location) { return match }
                index = NSMaxRange(match)
            }
            return lineEnd == NSNotFound ? nil : NSRange(location: lineEnd, length: 1)
        }
        let newline = input.rangeOfCharacter(from: .newlines, range: range)
        return newline.location == NSNotFound ? nil : newline
    }

    private func isEscaped(_ input: NSString, at index: Int) -> Bool {
        var start = index
        while start > 0, input.character(at: start - 1) == 92 { start -= 1 }
        return (index - start) % 2 != 0
    }

    private func appendWords(in text: String, input: NSString, range: NSRange, to spans: inout [SyntaxSpan]) {
        guard range.length > 0 else { return }
        if markup {
            spans += Self.tags.matches(in: text, range: range).map { SyntaxSpan(range: $0.range, role: .tag) }
            return
        }
        if colorsKeys {
            spans += Self.keys.matches(in: text, range: range).map { SyntaxSpan(range: $0.range, role: .tag) }
        }
        for match in Self.wordsAndNumbers.matches(in: text, options: .withTransparentBounds, range: range) {
            let token = input.substring(with: match.range)
            let word = ignoresCase ? token.lowercased() : token
            let role: SyntaxRole?
            if match.range(withName: "number").location != NSNotFound { role = .number }
            else if Self.literals.contains(word) { role = .literal }
            else if keywords.contains(word) { role = .keyword }
            else { role = nil }
            if let role { spans.append(SyntaxSpan(range: match.range, role: role)) }
        }
    }
}
