import NetFS
import SwiftUI

struct RemoteLocation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let name: String
    let address: URL

    static func parse(_ input: String) -> URL? {
        guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["smb", "sftp", "https", "http", "webdav", "webdavs"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.hasPrefix("-"),
              components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        if scheme == "sftp" {
            guard host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .range(of: #"^[a-zA-Z0-9.:_-]+$"#, options: .regularExpression) != nil,
                  components.user.map({ $0.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$"#,
                                                options: .regularExpression) != nil }) ?? true else { return nil }
        }
        if scheme == "webdav" { components.scheme = "http" }
        else if scheme == "webdavs" { components.scheme = "https" }
        else { components.scheme = scheme }
        return components.url
    }

    func connect() throws -> URL {
        if address.scheme == "sftp" { return try mountSFTP() }
        if let mounted = MountedLocation.list().first(where: { Self.sameShare($0.remote, address) }) {
            return mounted.url
        }
        if address.user == nil, address.scheme == "https" || address.scheme == "http" {
            return try mount(executable: "/sbin/mount_webdav", arguments: ["-s", "-S", "-v", name, address.absoluteString])
        }

        var mountPoints: Unmanaged<CFArray>?
        let options = NSMutableDictionary()
        if let host = address.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            options["AllowLoopback"] = true
        }
        if address.user?.lowercased() == "guest" {
            options["Guest"] = true
            options["UIOption"] = "NoUI"
        }
        let status = NetFSMountURLSync(address as CFURL, nil, nil, nil, options as CFMutableDictionary, nil, &mountPoints)
        let paths = mountPoints?.takeRetainedValue() as? [String] ?? []
        if status == 0, let path = paths.first { return URL(fileURLWithPath: path, isDirectory: true) }
        if let mounted = MountedLocation.list().first(where: { Self.sameShare($0.remote, address) }) {
            return mounted.url
        }
        if status == -128 { throw CancellationError() }
        if status > 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        throw RemoteError(message: "macOS 未能挂载服务器（\(status)）。")
    }

    private static func sameShare(_ left: URL?, _ right: URL) -> Bool {
        guard let left, left.scheme?.lowercased() == right.scheme?.lowercased(),
              left.host?.lowercased() == right.host?.lowercased(), left.port == right.port else { return false }
        if let user = right.user, left.user?.lowercased() != user.lowercased() { return false }
        let trim = CharacterSet(charactersIn: "/")
        return left.path.trimmingCharacters(in: trim) == right.path.trimmingCharacters(in: trim)
    }

    private func mountSFTP() throws -> URL {
        let fm = FileManager.default
        let binaries = ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs", "/opt/local/bin/sshfs"]
        guard let executable = binaries.first(where: fm.isExecutableFile(atPath:)) else {
            throw RemoteError(message: "SFTP 挂载需要 macFUSE 和 SSHFS。安装后请用 SSH 密钥连接。")
        }
        guard let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
              let host = components.host else { throw RemoteError(message: "SFTP 地址无效。") }
        let hostArgument = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let authority = components.user.map { $0 + "@" + hostArgument } ?? hostArgument
        let remote = authority + ":" + (components.path.isEmpty ? "/" : components.path)
        return try mount(executable: executable, arguments: [
            "-p", String(components.port ?? 22), "-o", "BatchMode=yes,StrictHostKeyChecking=yes,ConnectTimeout=15,reconnect", remote
        ])
    }

    private func mount(executable: String, arguments: [String]) throws -> URL {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true).appendingPathComponent("wfolder/Remote", isDirectory: true)
        let mount = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if MountedLocation.isMounted(mount) { return mount }
        try fm.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        let log = fm.temporaryDirectory.appendingPathComponent("wfolder-mount-" + UUID().uuidString)
        try Data().write(to: log, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: log) }
        let errors = try FileHandle(forUpdating: log)
        defer { try? errors.close() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [mount.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, MountedLocation.isMounted(mount) { return mount }
        try errors.seek(toOffset: 0)
        let details = String(decoding: try errors.read(upToCount: 4096) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = mount.withUnsafeFileSystemRepresentation { $0.map { rmdir($0) } }
        throw RemoteError(message: details.isEmpty ? "无法挂载远程位置。" : details)
    }

}

private struct RemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MountedLocation: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let remote: URL?
    let isNetwork: Bool
    private let stamp: FileStamp?

    var canUnmount: Bool { stamp != nil }
    var unmountTitle: String { isNetwork ? "断开连接" : "推出" }

    func unmount() throws {
        guard let stamp, url.path != "/" else {
            throw RemoteError(message: "此磁盘无法推出。")
        }
        guard Self.isMounted(url), stamp.sameObject(as: FileStamp(url)) else {
            throw RemoteError(message: "此位置已断开或已重新挂载，请刷新后重试。")
        }
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    static func isMounted(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        let values = try? fresh.resourceValues(forKeys: [.volumeURLKey])
        return values?.volume?.standardizedFileURL.path == fresh.standardizedFileURL.path
    }

    static func contains(_ root: URL, directory: URL) -> Bool {
        root.path == directory.path || directory.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }

    static func list() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeURLForRemountingKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                     options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path != "/" }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                var unmountable: ObjCBool = false
                let hasInfo = NSWorkspace.shared.getFileSystemInfo(forPath: url.path, isRemovable: nil, isWritable: nil,
                                                                  isUnmountable: &unmountable, description: nil, type: nil)
                return Self(url: url, name: values?.volumeLocalizedName ?? url.lastPathComponent,
                            remote: values?.volumeURLForRemounting, isNetwork: values?.volumeIsLocal == false,
                            stamp: hasInfo && unmountable.boolValue ? FileStamp(url) : nil)
            }
    }
}

enum CloudFileState: String, Sendable {
    case online = "仅云端", local = "已下载", syncing = "同步中", failure = "同步异常"

    var symbol: String {
        switch self {
        case .online: return "icloud.and.arrow.down"
        case .local: return "checkmark.icloud"
        case .syncing: return "arrow.trianglehead.clockwise.icloud"
        case .failure: return "exclamationmark.icloud"
        }
    }

    init?(_ values: URLResourceValues?) {
        guard let values, values.isUbiquitousItem == true else { return nil }
        if values.ubiquitousItemDownloadingError != nil || values.ubiquitousItemUploadingError != nil { self = .failure }
        else if values.ubiquitousItemIsDownloading == true || values.ubiquitousItemIsUploading == true { self = .syncing }
        else if values.ubiquitousItemDownloadingStatus == .notDownloaded { self = .online }
        else if values.ubiquitousItemDownloadingStatus != nil { self = .local }
        else { return nil }
    }
}

struct RemoteLocationsView: View {
    let workspace: BrowserWorkspace
    @ViewState private var name = ""
    @ViewState private var address = ""
    @ViewState private var mountError: String?
    @ViewState private var mounts: [MountedLocation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("服务器与磁盘").font(.headline)
            HStack {
                TextField("名称", text: $name).frame(width: 145)
                TextField("smb://服务器/共享目录", text: $address)
                Button("保存位置", action: save).disabled(RemoteLocation.parse(address) == nil)
            }
            Text("支持 SMB、WebDAV 和 SFTP。SFTP 通过 SSHFS 使用本机的 SSH 密钥。")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if !workspace.remoteLocations.isEmpty {
                    Section("已保存") {
                        ForEach(workspace.remoteLocations) { location in
                            HStack {
                                VStack(alignment: .leading) {
                                    Label(location.name, systemImage: "network")
                                    Text(location.address.absoluteString).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("连接并打开") { connect(location) }.disabled(workspace.connectingRemote != nil)
                            }
                            .contextMenu { Button("移除位置") { workspace.removeRemote(location) } }
                        }
                    }
                }
                if !mounts.isEmpty {
                    Section("已挂载") {
                        ForEach(mounts) { volume in
                            Button {
                                workspace.openLocationPane(volume.url, mounted: true)
                                workspace.presentedTool = nil
                            } label: {
                                Label(volume.name, systemImage: volume.isNetwork ? "network" : "externaldrive")
                            }.buttonStyle(.plain).help(volume.url.path)
                        }
                    }
                }
            }
            if let message = mountError { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if workspace.connectingRemote != nil { ProgressView("正在连接服务器…").controlSize(.small) }
                Spacer()
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 610, height: 420)
        .task {
            mounts = await Task.detached { MountedLocation.list() }.value
        }
    }

    private func save() {
        guard let url = RemoteLocation.parse(address) else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.saveRemote(RemoteLocation(name: value.isEmpty ? (url.host ?? url.absoluteString) : value, address: url))
        name = ""
        address = ""
    }

    private func connect(_ location: RemoteLocation) {
        mountError = nil
        Task {
            do {
                try await workspace.connectRemote(location)
                workspace.presentedTool = nil
            } catch is CancellationError {
                return
            } catch {
                mountError = error.localizedDescription
            }
        }
    }
}
