import SwiftUI

struct QuickAccessView: View {
    let workspace: BrowserWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("快速访问").font(.title2.weight(.semibold))
                pinned
                if !workspace.frequentFiles.recentItems.isEmpty { recent }
                if !workspace.namedWorkspaces.isEmpty { workspaces }
            }
            .frame(maxWidth: 760)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityLabel("快速访问")
    }

    private var pinned: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已固定").font(.headline)
            if workspace.quickAccessPins.isEmpty {
                Text("从文件或文件夹的右键菜单固定项目。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("常用位置").font(.headline).padding(.top, 8)
                ForEach(BrowserModel.defaults.filter { ["桌面", "文稿", "下载"].contains($0.name) }) { place in
                    row(place.name, icon: place.symbol, subtitle: nil) { workspace.navigateToFolder(place.url) }
                }
            } else {
                ForEach(workspace.quickAccessPins) { item in
                    row(item.title, icon: item.isFolder ? "folder" : "doc", subtitle: item.url.deletingLastPathComponent().path) {
                        workspace.openQuickAccessItem(item.url)
                    }
                    .draggable(item.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let source = items.first, source != item.id,
                              workspace.quickAccessPins.contains(where: { $0.id == source }) else { return false }
                        workspace.moveQuickAccessPin(source, to: item.id)
                        return true
                    }
                    .contextMenu { pinActions(item) }
                }
            }
        }
    }

    @ViewBuilder private func pinActions(_ item: QuickAccessPin) -> some View {
        let pins = workspace.quickAccessPins
        if let index = pins.firstIndex(of: item) {
            if index > pins.startIndex {
                Button("上移") { workspace.moveQuickAccessPin(item.id, to: pins[index - 1].id) }
            }
            if index + 1 < pins.endIndex {
                Button("下移") { workspace.moveQuickAccessPin(item.id, to: pins[index + 1].id) }
            }
        }
        Button("取消固定") { workspace.activeBrowser.toggleFavorite(item.url, isFolder: item.isFolder) }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近打开").font(.headline)
            ForEach(workspace.frequentFiles.recentItems) { item in
                let file = item.file
                row(file.filename, icon: file.glyph.symbol, subtitle: file.url.deletingLastPathComponent().path) {
                    workspace.openQuickAccessItem(file.url)
                }
                .contextMenu {
                    let pinned = workspace.activeBrowser.isFavorite(file.url)
                    Button(pinned ? "取消固定" : "固定到快速访问") {
                        workspace.activeBrowser.toggleFavorite(file.url, isFolder: false)
                    }
                    Button("前往所在文件夹") { workspace.revealInFolder(file.url) }
                    Button("移出最近打开") { workspace.frequentFiles.remove(item) }
                }
            }
        }
    }

    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工作区").font(.headline)
            ForEach(workspace.namedWorkspaces) { saved in
                row(saved.name, icon: "rectangle.split.2x1", subtitle: nil) { workspace.openWorkspace(saved) }
            }
        }
    }

    private func row(_ title: String, icon: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
        .help(subtitle.map { title + "\n" + $0 } ?? title)
    }
}

struct BrowserGeneralSettings: View {
    @AppStorage("wfolder.restoreLastSession") private var restoresSession = true
    @AppStorage("wfolder.newTabsShowQuickAccess") private var newTabsShowQuickAccess = true

    var body: some View {
        Form {
            Toggle("启动时恢复上次会话", isOn: $restoresSession)
            Toggle("新建标签页打开快速访问", isOn: $newTabsShowQuickAccess)
        }
        .formStyle(.grouped)
        .frame(width: 570, height: 350)
    }
}
