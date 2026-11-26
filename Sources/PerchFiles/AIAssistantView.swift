import SwiftUI

struct AIAssistantView: View {
    let workspace: BrowserWorkspace
    @Bindable var conversation: AIConversation
    let isInSidebar: Bool
    let changePlacement: () -> Void
    let close: () -> Void
    let performAction: (@escaping () -> Void) -> Void

    private enum Configuration { case service, permissions(URL?) }
    @ViewState private var configuration: Configuration?
    @ViewState private var showsHistory = false
    @ViewState private var deleting: AIChatRecord?
    @ViewState private var followsLatest = true
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let settings = AISettingsStore.shared
    private let examples = [
        ("找最近 7 天修改的 PDF", "magnifyingglass"),
        ("帮我整理下载目录", "folder"),
        ("把选中的文件移到下载目录", "folder"),
    ]

    var body: some View {
        Group {
            if isInSidebar {
                chat.popover(isPresented: Binding(
                    get: { configuration != nil }, set: { if !$0 { configuration = nil } }
                ), arrowEdge: .trailing) {
                    if let configuration { configurationView(configuration) }
                }
            } else if let configuration {
                configurationView(configuration)
            } else {
                HStack(spacing: 0) {
                    if showsHistory {
                        historySidebar.frame(width: 184)
                        Divider()
                    }
                    chat
                }
                .frame(width: showsHistory ? 839 : 654, height: 530)
                .onAppear { editing = true }
            }
        }
        .alert("删除对话？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { record in
            Button("删除对话", role: .destructive) { conversation.delete(record.id) }
            Button("取消", role: .cancel) {}
        } message: { record in
            Text(record.title)
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if isInSidebar, workspace.assistantFocusRequest > 0 { editing = true }
        }
        .onChange(of: workspace.assistantFocusRequest) {
            if isInSidebar { editing = true }
        }
    }

    @ViewBuilder private func configurationView(_ configuration: Configuration) -> some View {
        switch configuration {
        case .service: AISettingsView { self.configuration = nil }
        case .permissions(let folder): AIPermissionsView(initialDirectory: folder) { self.configuration = nil }
        }
    }

    private var header: some View {
        HStack(spacing: isInSidebar ? 7 : 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 助手").font(.headline)
                HStack(spacing: 5) {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(workspace.activeBrowser.directoryName).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(workspace.activeBrowser.directory.path)
            }
            Spacer(minLength: isInSidebar ? 4 : 14)
            if isInSidebar {
                historyButton.popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                    historySidebar.frame(width: 225, height: 310)
                }
            } else {
                historyButton
            }
            Button("新对话", systemImage: "square.and.pencil") {
                conversation.reset()
                editing = true
            }
            .labelStyle(.iconOnly)
            .help("新对话")
            .disabled((conversation.turns.isEmpty && conversation.draft.isEmpty) || conversation.isReplying)

            Button("自动整理权限", systemImage: "lock.shield") {
                configuration = .permissions(workspace.directoryBrowser?.directory)
            }
            .labelStyle(.iconOnly)
            .help("自动整理权限")
            .disabled(conversation.isReplying)

            Button("配置服务", systemImage: "gearshape") { configuration = .service }
                .labelStyle(.iconOnly)
                .help("配置服务")
                .disabled(conversation.isReplying)

            let placementLabel = isInSidebar ? "在弹窗中打开" : "固定到侧边栏"
            Button(placementLabel, systemImage: isInSidebar ? "macwindow" : "pin", action: changePlacement)
                .labelStyle(.iconOnly)
                .help(placementLabel)

            let closeLabel = isInSidebar ? "隐藏助手侧边栏" : "关闭助手"
            Button(closeLabel, systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .help(closeLabel)
                .keyboardShortcut(isInSidebar ? nil : .cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, isInSidebar ? 12 : 22)
        .padding(.vertical, isInSidebar ? 9 : 13)
    }

    private var historyButton: some View {
        Button("对话历史", systemImage: "clock.arrow.circlepath") { showsHistory.toggle() }
            .labelStyle(.iconOnly)
            .help("对话历史")
            .accessibilityValue(showsHistory ? "已展开" : "已收起")
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("对话历史")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 15)
            if conversation.records.isEmpty {
                Text("发送消息后，对话会保存在这里。")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(conversation.records) { record in
                            let selected = conversation.activeID == record.id
                            Button {
                                conversation.select(record.id)
                                if isInSidebar { showsHistory = false }
                                editing = true
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title).lineLimit(1)
                                    Text(record.updated, style: .date)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(record.title)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .contextMenu {
                                Button("删除对话…", role: .destructive) { deleting = record }
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                }
                .disabled(conversation.isReplying)
            }
        }
        .background(.quaternary.opacity(0.32))
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: isInSidebar ? 14 : 22) {
                    if conversation.turns.isEmpty {
                        welcome
                    }
                    ForEach(conversation.turns) { turn in
                        VStack(spacing: isInSidebar ? 12 : 16) {
                            userMessage(turn.prompt)
                            assistantMessage {
                                if let preface = turn.preface { Text(format(preface)).textSelection(.enabled) }
                                reply(to: turn)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("latestMessage")
                }
                .padding(.horizontal, isInSidebar ? 12 : 24)
                .padding(.top, isInSidebar ? 12 : 22)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scroll.scrollTo("latestMessage", anchor: .bottom) }
            .modifier(ChatScrollTracking(followsLatest: $followsLatest))
            .onChange(of: conversation.partialText) {
                if followsLatest { scroll.scrollTo("latestMessage", anchor: .bottom) }
            }
            .onChange(of: conversation.scrollRevision) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    scroll.scrollTo("latestMessage", anchor: .bottom)
                }
            }
        }
    }

    private var welcome: some View {
        assistantMessage {
            Text("我可以帮你查找、预览和整理文件。你想做什么？")
                .font(.body)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(examples, id: \.0) { example, icon in
                    Button {
                        conversation.draft = example
                        editing = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon).frame(width: 15)
                            Text(example)
                            Image(systemName: "arrow.up.right").font(.caption2)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    private func userMessage(_ message: String) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("你").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(verbatim: message)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: 444, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    private func assistantMessage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: isInSidebar ? 7 : 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: isInSidebar ? 24 : 28, height: isInSidebar ? 24 : 28)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8, content: {
                Text("wfolder 助手").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                content()
            })
            .padding(.top, 5)
            .frame(maxWidth: 518, alignment: .leading)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func reply(to turn: AIConversation.Turn) -> some View {
        switch turn.reply {
        case .pending:
            if !conversation.partialText.isEmpty {
                Text(format(conversation.partialText)).textSelection(.enabled)
                Label("正在生成", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在生成回复…").foregroundStyle(.secondary)
                }
            }
        case .organizing, .stopping:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(conversation.isStopping ? "正在停止整理…" : "正在自动整理文件…")
                    .foregroundStyle(.secondary)
            }
        case .searching:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("正在本机搜索文件…").foregroundStyle(.secondary)
            }
        case .answer(let message):
            Text(format(message)).textSelection(.enabled)
        case .searchResult(let summary):
            AIActionCard(title: summary.title, details: summary.details) {
                Button("查看结果") { performAction { workspace.showSmartFolderResults(summary.folder) } }
                    .buttonStyle(.bordered)
                Button("换目录重搜…") { chooseSearchDirectory(for: summary.folder) }
                    .buttonStyle(.bordered)
                    .disabled(conversation.isReplying)
            }
        case .proposal(let proposal, _):
            AIActionCard(title: proposal.title, details: proposal.details) {
                let layout = isInSidebar ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                layout {
                    if let label = proposal.button {
                        Button(label) {
                            if let apply = conversation.confirm(turn.id, in: workspace) { performAction(apply) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let rule = proposal.organizationRule {
                        Button("自动整理权限…") {
                            let scope = AIAutomationPermissions.shared.scope
                            configuration = .permissions(scope.permits(rule.source) ? rule.destination : rule.source)
                        }
                    }
                }
            }
        case .organizationResult(let title, let details):
            AIActionCard(title: title, details: details) {}
        case .previousProposal(let title, let details):
            AIActionCard(title: title, details: details) {
                Text("这项操作尚未执行。").font(.caption).foregroundStyle(.secondary)
                reuse(turn)
            }
        case .archived(let title, let details, let status):
            if details.isEmpty {
                archivedSummary(title, status: status)
            } else {
                DisclosureGroup {
                    AIActionDetails(details: details).padding(.top, 7)
                } label: {
                    archivedSummary(title, status: status)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            reuse(turn)
        case .stopped:
            Text("已停止生成。").foregroundStyle(.secondary)
            reuse(turn)
        case .interrupted:
            Text("上次回复未完成。").foregroundStyle(.secondary)
            reuse(turn)
        }
    }

    private func chooseSearchDirectory(for folder: SmartFolder) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = folder.root
        panel.prompt = "重新搜索"
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            conversation.rerunSearch(folder, at: directory, in: workspace)
        }
    }

    private func archivedSummary(_ title: String, status: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: title).font(.callout)
            Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func format(_ message: String) -> AttributedString {
        var rich = (try? AttributedString(markdown: message, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message)
        rich.link = nil
        return rich
    }

    private func reuse(_ turn: AIConversation.Turn) -> some View {
        Button("重新编辑") {
            conversation.draft = turn.prompt
            editing = true
        }
        .controlSize(.small)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 9) {
                TextField("发消息给 wfolder…", text: $conversation.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...4)
                    .focused($editing)
                    .accessibilityLabel("发消息给 wfolder")
                    .onKeyPress(keys: [.return], phases: .down, action: handleReturn)
                HStack {
                    Text(settings.provider.title).lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if conversation.isReplying {
                        let title = conversation.isOrganizing ? "停止整理" : conversation.isSearching ? "停止搜索" : "停止生成"
                        Button(title, systemImage: "stop.fill", action: conversation.stop)
                            .labelStyle(.iconOnly)
                            .help(title)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .disabled(conversation.isStopping)
                    } else {
                        Button("发送消息", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly)
                        .help("发送消息（↩） · 换行（⇧↩）")
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!conversation.canSend)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(editing ? Color.accentColor.opacity(0.46) : Color.primary.opacity(0.10))
                    .allowsHitTesting(false)
            }
            if conversation.isOverLimit {
                Text("消息最多支持 4,000 个字符。").font(.caption).foregroundStyle(.red)
            } else if let issue = conversation.historyIssue {
                Text(issue).font(.caption).foregroundStyle(.red)
            } else {
                Text("当前消息和近期对话会发送给模型。文件与选区在本机处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, isInSidebar ? 12 : 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func send() {
        conversation.send(in: workspace)
        editing = true
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextInputClient
        if editor?.hasMarkedText() == true { return .ignored }
        if press.modifiers == .shift {
            if let editor {
                editor.insertText("\n", replacementRange: editor.selectedRange())
            } else {
                conversation.draft += "\n"
            }
            return .handled
        }
        guard press.modifiers.isEmpty else { return .ignored }
        send()
        return .handled
    }
}

private struct ChatScrollTracking: ViewModifier {
    @Binding var followsLatest: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height - $0.visibleRect.maxY < 90
            } action: { _, nearEnd in followsLatest = nearEnd }
        } else {
            content
        }
    }
}

private struct AIActionCard<Footer: View>: View {
    let title: String
    let details: [String]
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: "arrow.turn.down.right")
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
            if !details.isEmpty {
                AIActionDetails(details: details)
            }
            footer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
    }
}

private struct AIActionDetails: View {
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(details.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
