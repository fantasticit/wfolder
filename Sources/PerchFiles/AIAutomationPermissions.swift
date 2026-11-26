import SwiftUI

struct AIFolderGrant: Codable, Identifiable, Sendable {
    let directory: URL
    private let identity: FileStamp

    init(directory: URL) throws {
        let physical = FileSystem.physicalDirectory(directory)
        guard let stamp = FileStamp(physical), stamp.directory else { throw TransferFileError.changedFolder }
        self.directory = physical
        identity = stamp
    }

    var id: URL { directory }
    var available: Bool { identity.sameObject(as: FileStamp(directory)) }

    func contains(_ resolved: URL) -> Bool {
        resolved.pathComponents.starts(with: directory.pathComponents) && available
    }
}

final class AIAutomationScope: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [AIFolderGrant]

    init(_ grants: [AIFolderGrant]) { self.grants = grants }

    fileprivate func update(_ grants: [AIFolderGrant]) {
        lock.withLock { self.grants = grants }
    }

    func permits(_ directory: URL) -> Bool {
        let current = lock.withLock { grants }
        guard !current.isEmpty else { return false }
        let physical = FileSystem.physicalDirectory(directory)
        return current.contains { $0.contains(physical) }
    }
}

@MainActor @Observable
final class AIAutomationPermissions {
    static let shared = AIAutomationPermissions()
    private static let storageKey = "wfolder.ai.organizationFolders"
    private let defaults: UserDefaults
    let scope: AIAutomationScope
    private(set) var grants: [AIFolderGrant]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([AIFolderGrant].self, from: $0) } ?? []
        grants = saved
        scope = AIAutomationScope(saved)
    }

    func grant(_ directory: URL) throws {
        let grant = try AIFolderGrant(directory: directory)
        try store(grants.filter { $0.id != grant.id } + [grant])
    }

    func revoke(_ grant: AIFolderGrant) throws {
        try store(grants.filter { $0.id != grant.id })
    }

    private func store(_ next: [AIFolderGrant]) throws {
        let data = try JSONEncoder().encode(next)
        scope.update(next)
        defaults.set(data, forKey: Self.storageKey)
        grants = next
    }
}

struct AIPermissionsView: View {
    var initialDirectory: URL? = nil
    var onClose: (() -> Void)? = nil

    private let permissions = AIAutomationPermissions.shared
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("自动整理权限", systemImage: "lock.shield").font(.headline)
                Spacer()
                if let onClose { Button("返回助手", action: onClose).keyboardShortcut(.cancelAction) }
            }
            Text("授权后，助手可在所选文件夹及其子目录内创建分类文件夹、移动或重命名文件。同名文件会跳过。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if permissions.grants.isEmpty {
                ContentUnavailableView("尚未授权文件夹", systemImage: "folder.badge.questionmark",
                                       description: Text("整理前会先展示方案。"))
            } else {
                List(permissions.grants) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(BrowserModel.placeName(for: grant.directory)).font(.callout.weight(.medium))
                            Text(grant.directory.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(grant.directory.path)
                        }
                        Spacer()
                        if !grant.available {
                            Text("需重新授权").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("撤销授权") {
                            do { try permissions.revoke(grant); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .listStyle(.inset)
            }
            Spacer(minLength: 0)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("授权保存在本机。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("授权文件夹…", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 570, height: 328)
    }

    private func chooseFolder() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = initialDirectory
        panel.prompt = "授权自动整理"
        panel.message = "允许 wfolder 的 AI 助手自动整理所选文件夹及其子目录。"
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let directory = panel.url else { return }
            do { try permissions.grant(directory); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}
