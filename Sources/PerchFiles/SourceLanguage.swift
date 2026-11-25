import Foundation

enum SourceLanguage: String, CaseIterable, Sendable {
    case sql = "SQL", typescript = "TypeScript", javascript = "JavaScript", swift = "Swift"
    case python = "Python", ruby = "Ruby", rust = "Rust", go = "Go", c = "C / Objective-C"
    case cpp = "C++", csharp = "C#", java = "Java", kotlin = "Kotlin", php = "PHP", lua = "Lua"
    case shell = "Shell", powershell = "PowerShell", docker = "Dockerfile", make = "Makefile"
    case html = "HTML", xml = "XML", css = "CSS", json = "JSON", yaml = "YAML", toml = "TOML", ini = "INI"

    private static let extensions: [String: Self] = [
        "sql": .sql, "pgsql": .sql, "psql": .sql,
        "tsx": .typescript, "cts": .typescript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "swift": .swift, "py": .python, "pyw": .python, "pyi": .python, "rb": .ruby,
        "rs": .rust, "go": .go, "c": .c, "h": .c, "m": .c, "mm": .cpp, "cc": .cpp,
        "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hxx": .cpp, "cs": .csharp,
        "java": .java, "kt": .kotlin, "kts": .kotlin, "php": .php, "lua": .lua,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "ps1": .powershell, "psm1": .powershell, "dockerfile": .docker, "mk": .make,
        "html": .html, "htm": .html, "xhtml": .html, "xml": .xml, "xsl": .xml, "xslt": .xml,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "json": .json, "jsonc": .json, "jsonl": .json, "yaml": .yaml, "yml": .yaml, "toml": .toml, "ini": .ini
    ]

    static func detect(_ url: URL) -> Self? {
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "makefile", "gnumakefile": return .make
        case "dockerfile", "containerfile": return .docker
        case ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile": return .shell
        case "gemfile", "rakefile": return .ruby
        default: break
        }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") { return .docker }
        let ext = url.pathExtension.lowercased()
        if ext == "ts" || ext == "mts" {
            return PagedPreviewSource.isTypeScriptText(url) ? .typescript : nil
        }
        return extensions[ext]
    }
}
