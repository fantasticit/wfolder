import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceTool: Identifiable {
    case workspaces, batchRename(BrowserModel, [FileEntry]), compare, spotlight, goToPath

    var id: String {
        switch self {
        case .workspaces: return "workspaces"
        case .batchRename: return "rename"
        case .compare: return "compare"
        case .spotlight: return "spotlight"
        case .goToPath: return "goToPath"
        }
    }
}

struct WorkspaceLibrary: View {
    let workspace: BrowserWorkspace
    @ViewState private var name = ""
    @ViewState private var duplicate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工作区").font(.headline)
            HStack {
                TextField("工作区名称", text: $name)
                Button("保存当前布局") {
                    if workspace.saveWorkspace(name: name) { workspace.presentedTool = nil }
                    else { duplicate = true }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            if duplicate { Text("已有同名工作区，请换一个名称。").font(.caption).foregroundStyle(.red) }
            Divider()
            if workspace.namedWorkspaces.isEmpty {
                ContentUnavailableView("暂无已保存的工作区", systemImage: "rectangle.split.2x1")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workspace.namedWorkspaces) { saved in
                    HStack {
                        Text(saved.name)
                        Spacer()
                        Button("打开") {
                            workspace.openWorkspace(saved)
                            workspace.presentedTool = nil
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 470, height: 330)
        .onAppear { name = workspace.activeBrowser.directoryName }
        .onChange(of: name) { duplicate = false }
    }
}

struct StashDrop: ViewModifier {
    let workspace: BrowserWorkspace
    @ViewState private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 5))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                for provider in files {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let direct = item as? URL { url = direct }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else { url = nil }
                        guard let url, url.isFileURL else { return }
                        DispatchQueue.main.async { workspace.storeInStash([url]) }
                    }
                }
                return !files.isEmpty
            }
    }
}
