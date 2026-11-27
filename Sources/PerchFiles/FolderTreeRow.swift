import SwiftUI

struct FolderTreeRow: View {
    let place: Place
    let model: BrowserModel
    let showHidden: Bool
    var usesAccent = true
    let navigate: (URL) -> Void
    let workspace: BrowserWorkspace

    @ViewState private var expanded = false
    @ViewState private var children: [Place]?
    @ViewState private var error: String?

    private struct LoadRequest: Equatable {
        let expanded: Bool
        let showHidden: Bool
        let contentsID: UUID?
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let error {
                Label("无法读取子文件夹", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(error)
            } else if let children {
                if children.isEmpty {
                    Text("无子文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(children) { child in
                        FolderTreeRow(place: child, model: model, showHidden: showHidden, navigate: navigate, workspace: workspace)
                    }
                }
            } else {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("正在读取子文件夹")
            }
        } label: {
            Button {
                navigate(place.url)
            } label: {
                SidebarItemLabel(title: place.name, symbol: place.symbol, usesAccent: usesAccent)
                    .fontWeight(place.id == model.directory.path ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            .help(place.url.path)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DirectoryDrop(directory: place.url, workspace: workspace))
        }
        .tag(place.id)
        .task(id: LoadRequest(expanded: expanded, showHidden: showHidden,
                              contentsID: place.id == model.directory.path ? model.contentsID : nil)) {
            guard expanded else { return }
            error = nil
            let url = place.url
            let worker = Task.detached(priority: .userInitiated) { try FileSystem.subfolders(url, showHidden: showHidden) }
            let outcome = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let folders):
                children = folders
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }
}

struct SidebarItemLabel: View {
    let title: String
    let symbol: String
    var usesAccent = true

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(usesAccent ? Color(nsColor: .systemBlue) : Color.secondary)
        }
    }
}
