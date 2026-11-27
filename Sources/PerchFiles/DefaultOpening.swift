import AppKit
import CoreServices
import UniformTypeIdentifiers

@MainActor
enum DefaultOpening {
    private static let previousKey = "wfolder.previousDefaultApplications"

    struct Application: Identifiable {
        let url: URL
        let bundleID: String?
        let name: String

        init(_ url: URL) {
            self.url = url
            let bundle = Bundle(url: url)
            bundleID = bundle?.bundleIdentifier
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        }

        var id: String { bundleID ?? url.standardizedFileURL.path }

        var isWfolder: Bool {
            if let bundleID, bundleID == Bundle.main.bundleIdentifier { return true }
            return url.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath()
        }
    }

    struct Association {
        var current: Application?
        var previous: Application?
        var alternatives: [Application] = []
    }

    struct Change {
        let type: UTType
        let application: Application
    }

    struct BatchResult {
        var changed = 0
        var alreadySet = 0
        var notProcessed = 0
        var failures: [(type: UTType, message: String)] = []
    }

    static var applicationURL: URL? {
        let bundle = Bundle.main
        guard let identifier = bundle.bundleIdentifier, bundle.bundleURL.pathExtension == "app" else { return nil }
        return resolveApplication(bundle.bundleURL, identifier: identifier)
    }

    static func resolveApplication(_ original: URL, identifier: String?) -> URL? {
        let original = original.resolvingSymlinksInPath()
        if validApplication(original, identifier: identifier) { return original }
        guard let identifier else { return nil }
        let applications = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let candidates = applications.map { $0.appendingPathComponent(original.lastPathComponent) } +
            [NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)].compactMap { $0 }
        return candidates.map { $0.resolvingSymlinksInPath() }.first { validApplication($0, identifier: identifier) }
    }

    private static func validApplication(_ url: URL, identifier: String?) -> Bool {
        guard url.isFileURL, url.pathExtension == "app", let bundle = Bundle(url: url),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        return identifier == nil || bundle.bundleIdentifier == identifier
    }

    static let documentTypes: [UTType] = {
        let definitions = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return definitions.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .compactMap { UTType($0) }
            .filter { $0 != .folder }
    }()

    static func current(for type: UTType) -> Application? {
        NSWorkspace.shared.urlForApplication(toOpen: type).map(Application.init)
    }

    static func previous(for type: UTType) -> Application? {
        previousApplications[type.identifier]
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map(Application.init)
    }

    static func association(for type: UTType) -> Association {
        let current = current(for: type)
        guard current?.isWfolder == true else { return Association(current: current) }

        let workspace = NSWorkspace.shared
        let previous = previous(for: type)
        let finder = type == .folder ? workspace.urlForApplication(withBundleIdentifier: "com.apple.finder") : nil
        let urls = [previous?.url, finder].compactMap { $0 } + workspace.urlsForApplications(toOpen: type)
        var seen = Set<String>()
        let alternatives = urls.map(Application.init).filter { !$0.isWfolder && seen.insert($0.id).inserted }
        return Association(current: current, previous: previous, alternatives: alternatives)
    }

    static func apply(_ changes: [Change], onProgress: (Int, Int, UTType) -> Void) async -> BatchResult {
        var result = BatchResult()
        for (index, change) in changes.enumerated() {
            onProgress(index + 1, changes.count, change.type)
            do {
                if try await set(change.application, for: change.type) { result.changed += 1 }
                else { result.alreadySet += 1 }
            } catch {
                if wasCancelled(error) {
                    result.notProcessed = changes.count - index
                    break
                }
                result.failures.append((change.type, error.localizedDescription))
            }
        }
        return result
    }

    @discardableResult
    static func set(_ application: Application, for type: UTType) async throws -> Bool {
        guard let appURL = resolveApplication(application.url, identifier: application.bundleID) else {
            throw ChangeError.missingApplication
        }
        if application.isWfolder { try checkLocation(appURL) }
        let registration = LSRegisterURL(appURL as CFURL, true)
        guard registration == noErr else { throw ChangeError.associationStatus(registration) }
        let before = current(for: type)
        guard before?.id != application.id else { return false }
        let workspace = NSWorkspace.shared
        if type == .folder {
            do {
                try await workspace.setDefaultApplication(at: appURL, toOpen: UTType.folder)
            } catch {
                if wasCancelled(error) { throw CancellationError() }
                let failure = error as NSError
                let detail = failure.userInfo[NSUnderlyingErrorKey] as? NSError ?? failure
                if detail.domain == NSOSStatusErrorDomain, [Int(kLSUnknownTypeErr), -50].contains(detail.code) {
                    throw ChangeError.folderUnsupported
                }
                throw ChangeError.folderFailed(detail.domain, detail.code)
            }
        } else {
            try await workspace.setDefaultApplication(at: appURL, toOpen: type)
        }
        if application.isWfolder {
            var previous = previousApplications
            previous[type.identifier] = before?.bundleID
            UserDefaults.standard.set(previous, forKey: previousKey)
        }
        for _ in 0..<25 {
            if current(for: type)?.id == application.id { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChangeError.pending
    }

    static func opensInWfolder(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url).map(Application.init)?.isWfolder == true
    }

    private static var previousApplications: [String: String] {
        UserDefaults.standard.dictionary(forKey: previousKey) as? [String: String] ?? [:]
    }

    private static func wasCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        if error is CancellationError ||
            (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) ||
            (nsError.domain == NSOSStatusErrorDomain && nsError.code == -128) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return (underlying.domain == NSOSStatusErrorDomain && underlying.code == -128) ||
                (underlying.domain == NSCocoaErrorDomain && underlying.code == NSUserCancelledError)
        }
        return false
    }

    private static func checkLocation(_ url: URL) throws {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/private/var/folders/") ||
            path.hasPrefix("/private/tmp/") ||
            (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            throw ChangeError.location
        }
    }

    private enum ChangeError: LocalizedError {
        case associationStatus(OSStatus), folderFailed(String, Int), location, pending, missingApplication, folderUnsupported

        var errorDescription: String? {
            switch self {
            case .folderUnsupported:
                return "当前 macOS 拒绝修改文件夹的默认应用。可选取文件夹在 wfolder 中打开，或使用访达右键「服务 → 在 wfolder 中打开」。"
            case .missingApplication: return "找不到所选应用。请从「应用程序」重新打开 wfolder，或重新选取应用。"
            case .associationStatus(let status): return "macOS 未能更新默认应用（\(status)）。"
            case .folderFailed(let domain, let code): return "macOS 未能更新文件夹关联（\(domain) \(code)）。"
            case .location: return "请将 wfolder.app 拖到「应用程序」，从那里重新打开后再设置。"
            case .pending: return "macOS 尚未报告新的默认应用。请刷新后查看。"
            }
        }
    }
}
