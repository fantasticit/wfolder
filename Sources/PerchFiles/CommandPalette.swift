import SwiftUI

enum PaneDirection: String, CaseIterable, Identifiable {
    case left, right, up, down
    var id: Self { self }
    var key: KeyEquivalent {
        switch self {
        case .left: return .leftArrow
        case .right: return .rightArrow
        case .up: return .upArrow
        case .down: return .downArrow
        }
    }
    var label: String {
        switch self {
        case .left: return "左"
        case .right: return "右"
        case .up: return "上"
        case .down: return "下"
        }
    }
}

extension PaneLayout {
    func frames(in rect: CGRect, proportions: [UUID: CGFloat]) -> [(UUID, CGRect)] {
        switch self {
        case .pane(let model): return [(model.id, rect)]
        case .split(let id, let direction, let first, let second):
            let ratio = max(0.001, min(0.999, proportions[id] ?? 0.5))
            let distance = direction == .sideBySide ? rect.minX + rect.width * ratio : rect.minY + rect.height * ratio
            let (a, b) = rect.divided(atDistance: distance - (direction == .sideBySide ? rect.minX : rect.minY),
                                     from: direction == .sideBySide ? .minXEdge : .minYEdge)
            return first.frames(in: a, proportions: proportions) + second.frames(in: b, proportions: proportions)
        }
    }

    func neighbor(of id: UUID, direction: PaneDirection, proportions: [UUID: CGFloat]) -> UUID? {
        let panes = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1), proportions: proportions)
        guard let current = panes.first(where: { $0.0 == id })?.1 else { return nil }
        return panes.compactMap { candidate, frame -> (UUID, CGFloat)? in
            guard candidate != id else { return nil }
            let x = frame.midX - current.midX
            let y = frame.midY - current.midY
            let side: CGFloat
            let gap: CGFloat
            let offset: CGFloat
            switch direction {
            case .left: side = -x; gap = current.minX - frame.maxX; offset = abs(y)
            case .right: side = x; gap = frame.minX - current.maxX; offset = abs(y)
            case .up: side = -y; gap = current.minY - frame.maxY; offset = abs(x)
            case .down: side = y; gap = frame.minY - current.maxY; offset = abs(x)
            }
            guard side > 0, gap >= -0.0001 else { return nil }
            let horizontal = direction == .left || direction == .right
            let overlap = horizontal
                ? min(frame.maxY, current.maxY) - max(frame.minY, current.minY)
                : min(frame.maxX, current.maxX) - max(frame.minX, current.minX)
            return (candidate, (overlap > 0 ? 0 : 2) + max(0, gap) + offset * 0.3)
        }.min(by: { $0.1 < $1.1 })?.0
    }
}

struct CommandPalette: View {
    private struct Action: Identifiable {
        let id: String
        let icon: String
        let run: () -> Void
    }

    let workspace: BrowserWorkspace
    @ViewState private var query = ""
    @ViewState private var selection: String?
    @FocusState private var focused: Bool

    private var actions: [Action] {
        let actions: [Action] = [
            .init(id: "AI 助手", icon: "sparkles", run: workspace.openAIAssistant),
            .init(id: "高级搜索", icon: "magnifyingglass") { workspace.presentedTool = .advancedSearch(nil) },
            .init(id: "前往路径", icon: "arrow.right.square") { workspace.presentedTool = .goToPath },
            .init(id: "左右分割面板", icon: "rectangle.split.2x1") { workspace.splitPane(.sideBySide) },
            .init(id: "上下分割面板", icon: "rectangle.split.1x2") { workspace.splitPane(.stacked) },
            .init(id: "文件暂存架", icon: "tray") { workspace.openStashPane() },
            .init(id: "传输队列", icon: "arrow.left.arrow.right") { workspace.revealOperations(.transfers) },
            .init(id: "服务器与磁盘", icon: "network") { workspace.presentedTool = .remote },
            .init(id: "整理规则", icon: "tray.and.arrow.down") { workspace.presentedTool = .organization },
            .init(id: "对比面板目录", icon: "rectangle.split.2x1") { workspace.presentedTool = .compare },
        ] + workspace.namedWorkspaces.map { saved in
            Action(id: "打开工作区 · " + saved.name, icon: "briefcase") { workspace.openWorkspace(saved) }
        } + workspace.smartFolders.map { folder in
            Action(id: "打开智能文件夹 · " + folder.name, icon: "folder.badge.gearshape") { workspace.openSmartFolder(folder) }
        }
        return query.isEmpty ? actions : actions.filter { $0.id.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索命令或工作区", text: $query).focused($focused)
                .onSubmit {
                    if let action = actions.first(where: { $0.id == selection }) ?? actions.first { perform(action) }
                }
                .onMoveCommand { direction in
                    if direction == .up || direction == .down {
                        let position = actions.firstIndex(where: { $0.id == selection }) ?? -1
                        let next = position + (direction == .down ? 1 : -1)
                        if actions.indices.contains(next) { selection = actions[next].id }
                    }
                }
            List(actions, selection: $selection) { action in
                Label(action.id, systemImage: action.icon).tag(action.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { perform(action) }
            }
            HStack {
                Button("关闭") { workspace.presentedTool = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("运行") {
                    if let action = actions.first(where: { $0.id == selection }) ?? actions.first { perform(action) }
                }.disabled(actions.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480, height: 340)
        .onAppear { focused = true }
        .onChange(of: query) { selection = actions.first?.id }
    }

    private func perform(_ action: Action) {
        workspace.presentedTool = nil
        Task { @MainActor in
            await Task.yield()
            action.run()
        }
    }
}

struct PathCompletion: Identifiable, Sendable {
    let url: URL
    let directory: Bool
    var id: URL { url }
    var path: String { url.path + (directory ? "/" : "") }

    static func suggestions(for input: String, root: URL, showHidden: Bool = false) -> [Self] {
        guard !input.isEmpty else { return [] }
        let expanded = (input as NSString).expandingTildeInPath
        let target = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
        let inDirectory = expanded.hasSuffix("/")
        let prefix = inDirectory ? "" : target.lastPathComponent
        let directory = (inDirectory ? target : target.deletingLastPathComponent()).standardizedFileURL
        let opts: FileManager.DirectoryEnumerationOptions = showHidden || prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: opts)) ?? []
        return files.filter { file in
            !Task.isCancelled && (prefix.isEmpty || file.lastPathComponent.range(
                of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .prefix(7).map { file in
            Self(url: file, directory: (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
    }

    static func load(_ input: String, root: URL) async -> [Self] {
        let worker = Task.detached(priority: .userInitiated) { suggestions(for: input, root: root) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}

struct PathCompletionRows: View {
    let suggestions: [PathCompletion]
    let choose: (PathCompletion) -> Void

    var body: some View {
        ForEach(suggestions) { suggestion in
            Button { choose(suggestion) } label: {
                Label(suggestion.url.lastPathComponent, systemImage: suggestion.directory ? "folder" : "doc")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .help(suggestion.url.path)
        }
    }
}
