import SwiftUI
import UniformTypeIdentifiers

struct DefaultOpeningSettingsView: View {
    @ViewState private var folder = DefaultOpening.Association()
    @ViewState private var fileApplications: [UTType: DefaultOpening.Application] = [:]
    @ViewState private var selected: Set<UTType> = []
    @ViewState private var changing: UTType?
    @ViewState private var progress: String?
    @ViewState private var folderIssue: String?
    @ViewState private var batchResult: DefaultOpening.BatchResult?

    private let types = DefaultOpening.documentTypes

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            folderSettings
            Divider()
            fileSettings
        }
        .padding(22)
        .frame(width: 600, height: 460, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private var folderSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("文件夹", systemImage: "folder").font(.headline)
            HStack(spacing: 10) {
                if let current = folder.current {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: current.url.path))
                        .resizable().frame(width: 19, height: 19).accessibilityHidden(true)
                }
                Text("当前默认应用 · " + (folder.current?.name ?? "未找到")).lineLimit(1)
                Spacer()
                if changing == .folder {
                    ProgressView().controlSize(.small).accessibilityLabel("正在设置文件夹")
                } else if folder.current?.isWfolder == true {
                    if let restore = folder.previous ?? folder.alternatives.first(where: { $0.bundleID == "com.apple.finder" }) {
                        Button("恢复为 \(restore.name)") { changeFolder(to: restore) }
                    }
                    Menu("更改为其他应用") { destinations(for: .folder, association: folder) }
                } else {
                    Button("设为 wfolder…") {
                        if let app = wfolder { changeFolder(to: app) }
                    }
                    .disabled(wfolder == nil)
                }
            }
            .disabled(changing != nil)
            if let folderIssue {
                Label(folderIssue, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text("适用于通过 macOS 打开的普通文件夹。桌面和 Dock 的访达入口由系统管理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fileSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("文件格式", systemImage: "doc").font(.headline)
                Spacer()
                Text("已选 \(selected.count) 项").font(.caption).foregroundStyle(.secondary)
                Button("全选") { selected = Set(types) }.disabled(selected.count == types.count)
                Button("清空") { selected.removeAll() }.disabled(selected.isEmpty)
            }
            .disabled(changing != nil)

            List(types, id: \.identifier) { type in
                fileRow(type)
            }
            .listStyle(.inset)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .disabled(changing != nil)

            HStack {
                if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let batchResult {
                    Text(summary(batchResult)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("各格式的默认应用会单独保存。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                let restore = restorationChanges
                if !restore.isEmpty {
                    Button("恢复 \(restore.count) 项") { apply(restore) }.disabled(changing != nil)
                }
                Button("将所选设为 wfolder…") {
                    guard let wfolder else { return }
                    apply(types.filter(selected.contains).map { .init(type: $0, application: wfolder) })
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || changing != nil || wfolder == nil)
            }
        }
    }

    private func fileRow(_ type: UTType) -> some View {
        HStack(spacing: 9) {
            Toggle(isOn: Binding(get: { selected.contains(type) }, set: { checked in
                if checked { selected.insert(type) } else { selected.remove(type) }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(typeLabel(type)).lineLimit(1)
                    if let failure = batchResult?.failures.first(where: { $0.type == type }) {
                        Text(failure.message).font(.caption).foregroundStyle(.red).lineLimit(2)
                            .help(failure.message)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if let app = fileApplications[type] {
                Text(app.name).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .trailing)
                    .help("当前默认应用 · " + app.name)
            }
            if fileApplications[type]?.isWfolder == true {
                Menu {
                    let association = DefaultOpening.association(for: type)
                    if let restore = association.previous {
                        Button("恢复为 \(restore.name)") { apply([.init(type: type, application: restore)]) }
                        Divider()
                    }
                    destinations(for: type, association: association)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更改 \(typeLabel(type)) 的默认应用")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func destinations(for type: UTType, association: DefaultOpening.Association) -> some View {
        ForEach(association.alternatives) { app in
            Button(app.name) { change(to: app, for: type) }
        }
        if !association.alternatives.isEmpty { Divider() }
        Button("选取应用…") { chooseApplication(for: type) }
    }

    private var wfolder: DefaultOpening.Application? {
        DefaultOpening.applicationURL.map(DefaultOpening.Application.init)
    }

    private var restorationChanges: [DefaultOpening.Change] {
        types.compactMap { type in
            guard selected.contains(type), fileApplications[type]?.isWfolder == true,
                  let previous = DefaultOpening.previous(for: type) else { return nil }
            return DefaultOpening.Change(type: type, application: previous)
        }
    }

    private func typeLabel(_ type: UTType) -> String {
        let name = type.localizedDescription ?? type.identifier
        if let ext = type.preferredFilenameExtension { return "\(name) (.\(ext))" }
        return name
    }

    private func summary(_ result: DefaultOpening.BatchResult) -> String {
        var parts = ["已更改 \(result.changed) 项"]
        if result.alreadySet > 0 { parts.append("已是目标应用 \(result.alreadySet) 项") }
        if !result.failures.isEmpty { parts.append("失败 \(result.failures.count) 项") }
        if result.notProcessed > 0 { parts.append("取消 \(result.notProcessed) 项") }
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        folder = DefaultOpening.association(for: .folder)
        for type in types { fileApplications[type] = DefaultOpening.current(for: type) }
    }

    private func chooseApplication(for type: UTType) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.prompt = "选取"
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url { change(to: DefaultOpening.Application(url), for: type) }
        }
    }

    private func change(to application: DefaultOpening.Application, for type: UTType) {
        if type == .folder { changeFolder(to: application) }
        else { apply([.init(type: type, application: application)]) }
    }

    private func changeFolder(to app: DefaultOpening.Application) {
        guard changing == nil else { return }
        changing = .folder
        folderIssue = nil
        Task {
            defer { changing = nil; refresh() }
            do { try await DefaultOpening.set(app, for: .folder) }
            catch { folderIssue = error.localizedDescription }
        }
    }

    private func apply(_ changes: [DefaultOpening.Change]) {
        guard changing == nil, let first = changes.first else { return }
        changing = first.type
        batchResult = nil
        Task {
            defer { changing = nil; progress = nil; refresh() }
            batchResult = await DefaultOpening.apply(changes) { index, total, type in
                changing = type
                progress = "正在设置 \(index)/\(total) · \(type.preferredFilenameExtension ?? type.identifier)"
            }
        }
    }
}
