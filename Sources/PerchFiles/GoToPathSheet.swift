import SwiftUI

struct GoToPathSheet: View {
    let baseDirectory: URL
    let go: (BrowserAddress) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var pathFocused: Bool
    @ViewState private var path = ""
    @ViewState private var invalidPath = false
    @ViewState private var suggestions: [PathCompletion] = []
    @ViewState private var validation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("前往路径", systemImage: "folder")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                TextField("路径", text: $path, prompt: Text("输入文件或文件夹路径"))
                    .textFieldStyle(.roundedBorder)
                    .focused($pathFocused)
                    .onSubmit(submit)
                    .onKeyPress(.tab) {
                        guard let match = suggestions.first, match.path != path else { return .ignored }
                        path = match.path
                        return .handled
                    }
                if validation != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("正在查找路径")
                }
            }
            PathCompletionRows(suggestions: suggestions) { match in
                path = match.path
                pathFocused = true
            }
            if invalidPath {
                Label("找不到此文件或文件夹，请检查路径。", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("前往", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty || validation != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { pathFocused = true }
        .onChange(of: path) {
            validation?.cancel()
            validation = nil
            invalidPath = false
        }
        .task(id: path) {
            suggestions = []
            let values = await PathCompletion.load(path, root: baseDirectory)
            if !Task.isCancelled { suggestions = values }
        }
        .onDisappear { validation?.cancel() }
    }

    private func submit() {
        guard !path.isEmpty, validation == nil else { return }
        let input = path
        let baseDirectory = baseDirectory
        invalidPath = false
        validation = Task {
            let address = await Task.detached(priority: .userInitiated) {
                BrowserAddress.resolve(input, relativeTo: baseDirectory)
            }.value
            guard !Task.isCancelled else { return }
            validation = nil
            if let address {
                dismiss()
                go(address)
            } else {
                invalidPath = true
                pathFocused = true
            }
        }
    }
}
