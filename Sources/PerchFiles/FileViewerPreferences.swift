import Foundation

@MainActor
struct FileViewerPreferences {
    private let global: String
    private let launchServices: String
    private let storage: UserDefaults
    private let viewerBackup = "wfolder.fileViewer.previous"
    private let folderBackup = "wfolder.folderHandler.previous"

    init(storage: UserDefaults = .standard, global: String = kCFPreferencesAnyApplication as String,
         launchServices: String = "com.apple.LaunchServices/com.apple.launchservices.secure") {
        self.storage = storage
        self.global = global
        self.launchServices = launchServices
    }

    var viewer: String? { read("NSFileViewer", domain: global) as? String }
    var canRestoreViewer: Bool { storage.dictionary(forKey: viewerBackup) != nil }
    var canRestoreFolder: Bool { storage.dictionary(forKey: folderBackup) != nil }
    var configuredFolder: String? {
        handlers.last(where: Self.isFolder)?["LSHandlerRoleAll"] as? String
    }

    func setViewer(_ identifier: String) throws {
        if !canRestoreViewer {
            storage.set(["value": viewer ?? "", "target": identifier], forKey: viewerBackup)
        }
        try write(identifier, key: "NSFileViewer", domain: global)
    }

    func restoreViewer() throws {
        guard let backup = storage.dictionary(forKey: viewerBackup),
              let target = backup["target"] as? String else { return }
        guard viewer == target else { throw PreferenceError.changed }
        let previous = backup["value"] as? String ?? ""
        try write(previous.isEmpty ? nil : previous, key: "NSFileViewer", domain: global)
        storage.removeObject(forKey: viewerBackup)
    }

    func setFolder(_ identifier: String) throws {
        if !canRestoreFolder {
            storage.set(["entries": handlers.filter(Self.isFolder), "target": identifier], forKey: folderBackup)
        }
        let values = handlers.filter { !Self.isFolder($0) } +
            [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": identifier]]
        try write(values, key: "LSHandlers", domain: launchServices)
    }

    func restoreFolder() throws {
        guard let backup = storage.dictionary(forKey: folderBackup),
              let target = backup["target"] as? String else { return }
        guard configuredFolder == target else { throw PreferenceError.changed }
        let original = backup["entries"] as? [[String: Any]] ?? []
        try write(handlers.filter { !Self.isFolder($0) } + original, key: "LSHandlers", domain: launchServices)
        storage.removeObject(forKey: folderBackup)
    }

    private var handlers: [[String: Any]] {
        read("LSHandlers", domain: launchServices) as? [[String: Any]] ?? []
    }

    private static func isFolder(_ value: [String: Any]) -> Bool {
        value["LSHandlerContentType"] as? String == "public.folder"
    }

    private func read(_ key: String, domain: String) -> Any? {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func write(_ value: Any?, key: String, domain: String) throws {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw PreferenceError.writeFailed
        }
        let actual = read(key, domain: domain)
        guard (actual == nil && value == nil) ||
                (actual as? NSObject)?.isEqual(value) == true else { throw PreferenceError.writeFailed }
    }

    enum PreferenceError: LocalizedError {
        case changed, writeFailed
        var errorDescription: String? {
            switch self {
            case .changed: return "该设置已被其他应用更改，请先核对当前配置。原配置备份仍保留。"
            case .writeFailed: return "无法保存用户偏好设置，请稍后重试。"
            }
        }
    }
}
