import SwiftUI

struct FolderTreeRow: View {
    let place: Place
    let model: BrowserModel
    let showHidden: Bool
    let navigate: (URL) -> Void

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
                        FolderTreeRow(place: child, model: model, showHidden: showHidden, navigate: navigate)
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
                Label {
                    Text(place.name)
                } icon: {
                    Image(systemName: place.symbol)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(place.id == model.directory.path ? .primary : .secondary)
                }
                    .fontWeight(place.id == model.directory.path ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(place.url.path)
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
