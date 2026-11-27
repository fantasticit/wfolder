import SwiftUI

struct BrowserView: View {
    private static let clipboardPoll = Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()

    @ViewState private var workspace: BrowserWorkspace
    @ViewState private var aiConversation = AIConversation()
    @ViewState private var mountedVolumes: [MountedLocation] = []
    @ViewState private var volumeRefreshID = UUID()
    @ViewState private var actionAfterToolDismissal: (() -> Void)?
    private let restoresSession: Bool
    private let onWorkspaceReady: (BrowserWorkspace) -> Void

    init(directory: URL?, restoresSession: Bool, onWorkspaceReady: @escaping (BrowserWorkspace) -> Void) {
        self.restoresSession = restoresSession
        self.onWorkspaceReady = onWorkspaceReady
        _workspace = State(initialValue: BrowserWorkspace(directory: directory ?? BrowserModel.home,
                                                          restoreSession: restoresSession))
    }

    private var model: BrowserModel { workspace.activeBrowser }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 164, ideal: 192, max: 270)
        } detail: {
            files
                .navigationTitle(workspace.activeTab.showsQuickAccess ? "快速访问" : model.directoryName)
                .toolbar { toolbar }
                .searchable(text: $model.query, isPresented: $model.presentsSearch,
                            placement: .toolbar, prompt: "搜索文件和文件夹")
                .inspector(isPresented: inspectorVisibility) {
                    inspectorContent
                        .inspectorColumnWidth(min: workspace.showsAIAssistantSidebar ? 300 : 240,
                                              ideal: workspace.showsAIAssistantSidebar ? 360 : 310,
                                              max: workspace.showsAIAssistantSidebar ? 560 : 520)
                }
        }
        .focusedSceneValue(\.browserWorkspace, workspace)
        .task { await refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            workspace.refreshMountedPanes()
            Task { await refreshVolumes() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            workspace.refreshMountedPanes()
            Task { await refreshVolumes() }
        }
        .onAppear {
            onWorkspaceReady(workspace)
            workspace.frequentFiles.refresh()
        }
        .task(id: workspace.snapshot) {
            guard restoresSession else { return }
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            workspace.saveSession(workspace.snapshot)
        }
        .onDisappear {
            if restoresSession { workspace.saveSession(workspace.snapshot) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if restoresSession { workspace.saveSession(workspace.snapshot) }
        }
        .onChange(of: workspace.aiMemory.feedback) { workspace.rerankSearches() }
        .onChange(of: workspace.activeTab.id, initial: true) {
            workspace.refreshClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusFileSearch)) { _ in
            workspace.showFolderBrowser()
            model.presentsSearch = true
        }
        .onChange(of: model.presentsSearch) { _, visible in
            if visible { workspace.showFolderBrowser() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshClipboard()
            workspace.frequentFiles.refresh()
            for browser in workspace.activeTab.browsers where !browser.busy {
                browser.refreshIfStarted()
            }
        }
        .onReceive(Self.clipboardPoll) { _ in
            if NSApp.isActive { workspace.refreshClipboard() }
        }
        .sheet(item: $model.prompt) { prompt in
            PromptView(prompt: prompt) { model.submit(prompt, value: $0, format: $1) }
        }
        .sheet(item: $model.expandedPreview) { ExpandedPreview(entry: $0) }
        .sheet(item: Binding(get: { workspace.transferChoice }, set: { workspace.transferChoice = $0 })) { choice in
            TransferTargetPicker(choice: choice, workspace: workspace)
        }
        .sheet(item: Binding(get: { workspace.destinationRequest }, set: { workspace.destinationRequest = $0 })) { request in
            TransferDestinationView(request: request, workspace: workspace)
        }
        .sheet(item: Binding(get: { workspace.projectMemoryRequest }, set: { workspace.projectMemoryRequest = $0 })) { project in
            ProjectMemoryEditor(memory: workspace.aiMemory, project: project) { workspace.projectMemoryRequest = nil }
        }
        .sheet(item: Binding(get: { workspace.workflowRequest }, set: { workspace.workflowRequest = $0 })) { request in
            FileWorkflowEditor(memory: workspace.aiMemory, draft: request.draft, selectionCount: request.entries.count,
                               run: request.browser.map { browser in
                                   { workflow in
                                       workspace.workflowRequest = nil
                                       Task { await workspace.runWorkflow(workflow, entries: request.entries, from: browser) }
                                   }
                               }) { workspace.workflowRequest = nil }
        }
        .sheet(item: Binding(get: { workspace.presentedTool }, set: { workspace.presentedTool = $0 }),
               onDismiss: {
                   let action = actionAfterToolDismissal
                   actionAfterToolDismissal = nil
                   action?()
               }) { tool in
            switch tool {
            case .workspaces: WorkspaceLibrary(workspace: workspace)
            case .batchRename(let browser, let entries):
                BatchRenameView(browser: browser, entries: entries, saveWorkflow: { rule in
                    dismissTool {
                        workspace.workflowRequest = FileWorkflowRequest(draft: FileWorkflow(name: "批量重命名", rename: rule),
                                                                        entries: entries, browser: browser)
                    }
                }) { workspace.presentedTool = nil }
            case .compare: FolderCompareView(workspace: workspace)
            case .spotlight: SpotlightSearchView(workspace: workspace)
            case .advancedSearch(let folder): AdvancedSearchView(workspace: workspace, existing: folder)
            case .commands: CommandPalette(workspace: workspace)
            case .remote: RemoteLocationsView(workspace: workspace)
            case .organization: OrganizationView(workspace: workspace)
            case .agent: AgentTasksView { workspace.presentedTool = nil }
            case .organizationDraft(let rule): OrganizationView(workspace: workspace, draft: rule)
            case .aiAssistant:
                AIAssistantView(
                    workspace: workspace, conversation: aiConversation, isInSidebar: false,
                    changePlacement: { dismissTool(then: workspace.pinAIAssistant) },
                    close: { workspace.presentedTool = nil }, performAction: dismissTool(then:)
                )
            case .goToPath:
                GoToPathSheet(baseDirectory: workspace.directoryBrowser?.directory ?? model.directory) {
                    workspace.followAddress($0)
                }
            }
        }
        .alert(item: $model.issue) { issue in
            Alert(title: Text(issue.title), message: Text(issue.message), dismissButton: .default(Text("好")))
        }
        .onChange(of: workspace.transfers.conflictJob?.reviewID) { _, review in
            if review != nil, workspace.presentedTool == nil, model.prompt == nil, model.expandedPreview == nil {
                workspace.revealOperations(.transfers)
            }
        }
    }

    private var inspectorVisibility: Binding<Bool> {
        Binding(
            get: { workspace.showsAIAssistantSidebar || (model.showPreview && !workspace.activeTab.showsQuickAccess) },
            set: { visible in
                if !visible {
                    model.showPreview = false
                    workspace.hideAIAssistantSidebar()
                } else if !workspace.showsAIAssistantSidebar {
                    model.showPreview = true
                }
            }
        )
    }

    @ViewBuilder private var inspectorContent: some View {
        if workspace.showsAIAssistantSidebar {
            VSplitView {
                if model.showPreview && !workspace.activeTab.showsQuickAccess {
                    previewPane.frame(minHeight: 132, idealHeight: 190, maxHeight: .infinity)
                }
                AIAssistantView(
                    workspace: workspace, conversation: aiConversation, isInSidebar: true,
                    changePlacement: workspace.openAIAssistantAsSheet, close: workspace.hideAIAssistantSidebar,
                    performAction: { $0() }
                )
                .frame(minHeight: 270, idealHeight: 420, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("AI 助手侧边栏")
            }
        } else {
            previewPane
        }
    }

    private var previewPane: some View {
        PreviewPane(model: model, openFolder: { workspace.navigateToFolder($0.url) })
    }

    private func dismissTool(then action: @escaping () -> Void) {
        actionAfterToolDismissal = action
        workspace.presentedTool = nil
    }

    private func refreshVolumes() async {
        let request = UUID()
        volumeRefreshID = request
        let volumes = await Task.detached { MountedLocation.list() }.value
        if !Task.isCancelled, volumeRefreshID == request { mountedVolumes = volumes }
    }

    private var sidebar: some View {
        let directoryModel = workspace.directoryBrowser ?? model
        let disk = Place(name: "本机磁盘", symbol: "internaldrive", url: URL(fileURLWithPath: "/", isDirectory: true))
        let knownPlaces = BrowserModel.defaults + [disk]
        let favorites = model.favorites.map { url in
            knownPlaces.first { $0.url == url }
                ?? Place(name: BrowserModel.placeName(for: url), symbol: "folder", url: url)
        }
        let shortcuts = BrowserModel.defaults.filter { !model.isFavorite($0.url) }
        let frequentItems = workspace.frequentFiles.items
        let showHidden = workspace.showHidden
        let selection = Binding<String?>(
            get: { model.isVirtual || workspace.activeTab.showsQuickAccess ? nil : model.directory.path },
            set: { value in
                if let value { workspace.navigateToFolder(URL(fileURLWithPath: value, isDirectory: true)) }
            }
        )

        return List(selection: selection) {
            Section {
                Button { workspace.openQuickAccess() } label: {
                    SidebarItemLabel(title: "快速访问", symbol: "house")
                        .fontWeight(workspace.activeTab.showsQuickAccess ? .semibold : .regular)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }
            Section {
                ForEach(shortcuts) { place in
                    FolderTreeRow(place: place, model: directoryModel, showHidden: showHidden,
                                  usesAccent: place.url != BrowserModel.home, navigate: workspace.navigateToFolder)
                }
            } header: {
                Text("常用位置").background(OverlayScrollIndicators())
            }
            if !frequentItems.isEmpty {
                Section("经常访问") {
                    // Keep sidebar row positions stable when a click changes the ranking.
                    ForEach(frequentItems.indices, id: \.self) { index in
                        let item = frequentItems[index]
                        let file = item.file
                        HStack {
                            Button { workspace.activeBrowser.openEntry(file) } label: {
                                SidebarItemLabel(title: file.name, symbol: file.glyph.symbol)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                        .selectionDisabled()
                        .help(file.url.path)
                        .contextMenu {
                            Button("前往所在文件夹") { workspace.revealInFolder(file.url) }
                            Button("从经常访问移除") { workspace.frequentFiles.remove(item) }
                        }
                    }
                }
            }
            if !favorites.isEmpty {
                Section("收藏") {
                    ForEach(favorites) { place in
                        FolderTreeRow(place: place, model: directoryModel, showHidden: showHidden,
                                      usesAccent: place.url != BrowserModel.home && place.url != disk.url,
                                      navigate: workspace.navigateToFolder)
                            .contextMenu { Button("取消收藏") { model.toggleFavorite(place.url) } }
                    }
                }
            }
            if !mountedVolumes.isEmpty {
                Section("磁盘与共享") {
                    ForEach(mountedVolumes) { volume in
                        Button { workspace.openLocationPane(volume.url, mounted: true) } label: {
                            SidebarItemLabel(title: volume.name, symbol: volume.isNetwork ? "network" : "externaldrive",
                                             usesAccent: false)
                        }
                        .buttonStyle(.plain)
                        .help(volume.url.path)
                        .contextMenu {
                            Button("打开", systemImage: "folder") { workspace.openLocationPane(volume.url, mounted: true) }
                            Button("复制路径", systemImage: "link") { model.copyPath(volume.url) }
                            if volume.canUnmount {
                                Divider()
                                Button(volume.unmountTitle, systemImage: "eject") {
                                    Task {
                                        await workspace.unmountLocation(volume)
                                        await refreshVolumes()
                                    }
                                }
                                .disabled(workspace.unmountingVolumes.contains(volume.id))
                            }
                        }
                    }
                }
            }
            if !workspace.remoteLocations.isEmpty {
                Section("服务器") {
                    ForEach(workspace.remoteLocations) { location in
                        Button {
                            Task {
                                do { try await workspace.connectRemote(location) }
                                catch is CancellationError { return }
                                catch { model.issue = BrowserIssue(title: "服务器连接失败", message: error.localizedDescription) }
                            }
                        } label: {
                            SidebarItemLabel(title: location.name, symbol: "network", usesAccent: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.connectingRemote != nil)
                        .contextMenu { Button("移除位置") { workspace.removeRemote(location) } }
                    }
                }
            }
            if !workspace.smartFolders.isEmpty {
                Section("智能文件夹") {
                    ForEach(workspace.smartFolders) { folder in
                        Button { workspace.openSmartFolder(folder) } label: {
                            SidebarItemLabel(title: folder.name, symbol: "folder.badge.gearshape")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑…") { workspace.presentedTool = .advancedSearch(folder) }
                            Button("移除") { workspace.removeSmartFolder(folder) }
                        }
                    }
                }
            }
            if !model.isFavorite(disk.url) {
                Section("位置") {
                    FolderTreeRow(place: disk, model: directoryModel, showHidden: showHidden,
                                  usesAccent: false, navigate: workspace.navigateToFolder)
                }
            }
            Section {
                Button { workspace.openStashPane() } label: {
                    HStack {
                        SidebarItemLabel(title: "文件暂存架", symbol: "tray")
                        Spacer()
                        if !workspace.stash.isEmpty {
                            Text("\(workspace.stash.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(StashDrop(workspace: workspace))
            }
        }
        .listStyle(.sidebar)
        .tint(.gray)
        .transaction(value: frequentItems.map(\.id)) {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button(action: chooseFolder) {
                    SidebarItemLabel(title: "选取文件夹…", symbol: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("新建文件夹…", systemImage: "folder.badge.plus", action: model.askNewFolder)
                ForEach(NewFileFormat.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.formats) { format in
                            Button(format.label) { model.askNewFile(format: format) }
                        }
                    }
                }
            } label: {
                Label("新建", systemImage: "plus")
            }
            .help("新建文件或文件夹")
            .disabled(!model.canModifyDirectory)

            Button {
                model.toggleFavorite(model.directory)
            } label: {
                Label(model.isFavorite(model.directory) ? "取消收藏" : "收藏文件夹",
                      systemImage: model.isFavorite(model.directory) ? "star.fill" : "star")
            }
            .help(model.isFavorite(model.directory) ? "取消收藏当前文件夹" : "收藏当前文件夹")
            .disabled(model.isStash)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("剪切", systemImage: "scissors") { model.copy(model.selectedEntries, cut: true) }
                .disabled(model.selectedIDs.isEmpty || !model.canQueueTransfer)
                .help("剪切（⌘X）")
            Button("复制", systemImage: "doc.on.doc") { model.copy(model.selectedEntries) }
                .disabled(model.selectedIDs.isEmpty)
                .help("复制（⌘C）")
            Button("粘贴", systemImage: "doc.on.clipboard") { model.paste() }
                .disabled(!model.canPaste)
                .help("粘贴到当前文件夹（⌘V）")
            if model.isStash {
                Button("移出暂存架", systemImage: "tray.and.arrow.up") {
                    workspace.removeFromStash(model.selectedEntries.map(\.url))
                }
                .disabled(model.selectedIDs.isEmpty)
            } else {
                Button("移到废纸篓…", systemImage: "trash") { model.askTrash(model.selectedEntries) }
                    .disabled(model.selectedIDs.isEmpty || !model.canModifyDirectory)
                    .help("移到废纸篓（⌘Delete）")
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            if AgentService.shared.grant != nil {
                let count = AgentService.shared.pendingCount
                Button {
                    AgentService.shared.present()
                } label: {
                    Label(count == 0 ? "Agent 任务" : "Agent 任务，\(count) 项待确认",
                          systemImage: count == 0 ? "tray" : "tray.fill")
                }
                .help("Agent 任务")
            }
            Button("AI 助手", systemImage: "sparkles", action: workspace.openAIAssistant)
                .help("AI 助手（⌥⌘A）")
            FileViewMenu(model: model, workspace: workspace)
            Button {
                if workspace.showsOperations { workspace.showsOperations = false }
                else { workspace.revealOperations(.transfers) }
            } label: {
                Label("文件操作", systemImage: workspace.transfers.conflictJob == nil
                      ? "arrow.left.arrow.right.circle" : "exclamationmark.circle.fill")
            }
            .help(workspace.transfers.unfinished == 0 ? "传输队列和操作历史"
                  : "\(workspace.transfers.unfinished) 个待处理传输任务")
            .popover(isPresented: Binding(get: { workspace.showsOperations }, set: { workspace.showsOperations = $0 })) {
                FileOperationsView(workspace: workspace)
            }
            Menu {
                Button("左右分割面板", systemImage: "rectangle.split.2x1") { workspace.splitPane(.sideBySide) }
                Button("上下分割面板", systemImage: "rectangle.split.1x2") { workspace.splitPane(.stacked) }
                Divider()
                Button("关闭当前面板", systemImage: "xmark") { workspace.closePane() }
                    .disabled(!workspace.canClosePane)
            } label: {
                Label("分割面板", systemImage: "rectangle.split.2x1")
            }
            .help("分割当前面板（⌘D / ⇧⌘D）")
            Menu {
                Button("保存或打开工作区…", systemImage: "briefcase") { workspace.presentedTool = .workspaces }
                Button("文件暂存架", systemImage: "tray", action: workspace.openStashPane)
                Button("对比面板目录…", systemImage: "arrow.left.arrow.right") { workspace.presentedTool = .compare }
                    .disabled(workspace.folderBrowsers.count < 2)
                Button("高级搜索…", systemImage: "line.3.horizontal.decrease") { workspace.presentedTool = .advancedSearch(nil) }
                Button("命令面板…", systemImage: "command") { workspace.presentedTool = .commands }
                Button("服务器与磁盘…", systemImage: "network") { workspace.presentedTool = .remote }
                Button("整理规则…", systemImage: "tray.and.arrow.down") { workspace.presentedTool = .organization }
                Button("Spotlight 搜索…", systemImage: "magnifyingglass") { workspace.presentedTool = .spotlight }
            } label: {
                Label("工作区工具", systemImage: "briefcase")
            }
            .help("工作区、暂存架、目录对比和 Spotlight 搜索")
            Button {
                model.showPreview.toggle()
            } label: {
                Label(model.showPreview ? "隐藏预览" : "显示预览", systemImage: "sidebar.right")
            }
            .help(model.showPreview ? "隐藏预览（⌥⌘P）" : "显示预览（⌥⌘P）")
        }
    }

    private var files: some View {
        let tab = workspace.activeTab
        return VStack(spacing: 0) {
            BrowserTabs(workspace: workspace).background(.bar)
            Divider()
            if tab.showsQuickAccess {
                QuickAccessView(workspace: workspace).id(tab.id)
            } else {
                PaneWorkspaceView(tab: tab, workspace: workspace).id(tab.id)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "打开"
        panel.directoryURL = workspace.directoryBrowser?.directory ?? model.directory
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { workspace.navigateToFolder(url) }
            }
        }
    }
}

private struct PaneWorkspaceView: View {
    let tab: BrowserWorkspace.Tab
    let workspace: BrowserWorkspace

    var body: some View {
        let panes = tab.browsers
        let numbers = Dictionary(uniqueKeysWithValues: panes.enumerated().map { ($0.element.id, $0.offset + 1) })
        GeometryReader { geometry in
            let minimum = tab.layout.minimumSize
            let layout = PaneLayoutView(layout: tab.layout, workspace: workspace,
                                        numbers: numbers, activePaneID: tab.focusedPaneID,
                                        proportions: tab.proportions)
            let overflow: Axis.Set = [
                minimum.width > geometry.size.width ? .horizontal : [],
                minimum.height > geometry.size.height ? .vertical : []
            ]
            if overflow.isEmpty {
                layout
            } else {
                ScrollViewReader { scroll in
                    ScrollView(overflow) {
                        layout.frame(width: max(minimum.width, geometry.size.width),
                                     height: max(minimum.height, geometry.size.height))
                            .background(OverlayScrollIndicators())
                    }
                    .onChange(of: tab.focusedPaneID, initial: true) {
                        scroll.scrollTo(tab.focusedPaneID)
                    }
                }
            }
        }
    }
}

private struct PaneLayoutView: View {
    let layout: PaneLayout
    let workspace: BrowserWorkspace
    let numbers: [UUID: Int]
    let activePaneID: UUID
    let proportions: [UUID: CGFloat]

    var body: some View {
        Group {
            switch layout {
            case .pane(let browser):
                BrowserPane(model: browser, workspace: workspace, number: numbers[browser.id] ?? 1,
                            showsHeader: numbers.count > 1, isActive: browser.id == activePaneID)
            case .split(let id, let direction, let first, let second):
                split(id, direction: direction, first: first, second: second)
            }
        }
        .frame(minWidth: layout.minimumSize.width, maxWidth: .infinity,
               minHeight: layout.minimumSize.height, maxHeight: .infinity)
        .id(layout.id)
    }

    private func child(_ layout: PaneLayout) -> PaneLayoutView {
        PaneLayoutView(layout: layout, workspace: workspace, numbers: numbers, activePaneID: activePaneID,
                       proportions: proportions)
    }

    private func split(_ id: UUID, direction: PaneSplitDirection, first: PaneLayout, second: PaneLayout) -> some View {
        let horizontal = direction == .sideBySide
        return GeometryReader { geometry in
            let extent = max(0, (horizontal ? geometry.size.width : geometry.size.height) - PaneLayout.dividerWidth)
            let lower = min(extent, horizontal ? first.minimumSize.width : first.minimumSize.height)
            let upper = max(lower, extent - (horizontal ? second.minimumSize.width : second.minimumSize.height))
            let splitAt = min(upper, max(lower, extent * (proportions[id] ?? 0.5)))
            let divider = PaneDivider(horizontal: horizontal, splitID: id, position: splitAt, extent: extent) { position in
                guard extent > 0 else { return }
                workspace.resizeSplit(id, ratio: min(upper, max(lower, position)) / extent)
            }
            if horizontal {
                HStack(spacing: 0) {
                    child(first).frame(width: splitAt)
                    divider.frame(width: PaneLayout.dividerWidth)
                    child(second).frame(width: extent - splitAt)
                }
            } else {
                VStack(spacing: 0) {
                    child(first).frame(height: splitAt)
                    divider.frame(height: PaneLayout.dividerWidth)
                    child(second).frame(height: extent - splitAt)
                }
            }
        }
        .coordinateSpace(name: id)
    }
}

private struct PaneDivider: View {
    let horizontal: Bool
    let splitID: UUID
    let position: CGFloat
    let extent: CGFloat
    let setPosition: (CGFloat) -> Void

    var body: some View {
        Rectangle()
            .fill(.bar)
            .overlay {
                Rectangle().fill(Color(nsColor: .separatorColor))
                    .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovered in
                let cursor: NSCursor = horizontal ? .resizeLeftRight : .resizeUpDown
                (hovered ? cursor : .arrow).set()
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(splitID))
                .onChanged { value in setPosition(horizontal ? value.location.x : value.location.y) })
            .accessibilityLabel(horizontal ? "左右面板分隔线" : "上下面板分隔线")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setPosition(position + extent * 0.05)
                case .decrement: setPosition(position - extent * 0.05)
                @unknown default: break
                }
            }
    }
}

private struct TransferTargetPicker: View {
    let choice: BrowserWorkspace.TransferChoice
    let workspace: BrowserWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择要\(choice.operation.title)到的面板").font(.headline)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(choice.targets) { target in
                        Button {
                            if workspace.transfer(choice.urls, into: target.browser.directory, operation: choice.operation, fromStash: choice.fromStash) {
                                workspace.transferChoice = nil
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.title).font(.callout.weight(.medium))
                                Text(target.browser.directory.path)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                    }
                }
                .background(OverlayScrollIndicators())
            }
            .frame(maxHeight: 290)
            Button("取消") { workspace.transferChoice = nil }.keyboardShortcut(.cancelAction)
        }
        .padding(18)
        .frame(width: 400)
    }
}

private struct BrowserPane: View {
    let model: BrowserModel
    let workspace: BrowserWorkspace
    let number: Int
    let showsHeader: Bool
    let isActive: Bool

    @ViewState private var fileListFocusRequest = 0
    @ViewState private var dropHint: FileDropHint?

    var body: some View {
        let actions = BrowserFileActions(model: model, workspace: workspace)
        let listing = model.listing
        let entries = listing.entries
        return GeometryReader { proxy in
            ZStack {
                if let archive = model.zipArchive {
                    ZipBrowserView(archive: archive, browser: model) {
                        if model.isArchivePane { workspace.closeArchivePane(model) }
                        else { model.closeZip() }
                    }.id(archive.id)
                        .simultaneousGesture(TapGesture().onEnded { workspace.activatePane(model) })
                } else if model.viewMode == .details {
                    FileTable(actions: actions, listing: listing, selection: model.selectedIDs,
                              settings: model.viewSettings, groupedRows: model.groupedRows, viewportWidth: proxy.size.width,
                              showsLocation: model.isVirtual || model.hasSearch, sortColumn: model.sortColumn, ascending: model.ascending,
                              focusRequest: fileListFocusRequest, showDropHint: indicateDrop)
                } else {
                    FileGrid(actions: actions, listing: listing, selection: model.selectedIDs, mode: model.viewMode,
                             showsLocation: model.isVirtual || model.hasSearch, showExtensions: model.viewSettings.showExtensions,
                             showsCheckboxes: model.viewSettings.showsSelectionCheckboxes == true,
                             focusRequest: fileListFocusRequest, showDropHint: indicateDrop)
                }
                if model.zipArchive != nil {
                    EmptyView()
                } else if model.loading, entries.isEmpty {
                    ProgressView(model.smartFolder != nil ? "正在搜索文件…"
                                 : model.isStash ? "正在读取暂存项目…" : "正在读取文件夹…")
                        .controlSize(.small)
                } else if let error = model.loadError, model.searchScope != .workspace || !model.hasSearch {
                    ContentUnavailableView {
                        Label(model.smartFolder != nil ? "搜索未完成" : "无法读取此文件夹",
                              systemImage: "exclamationmark.folder")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { model.refresh() }
                    }
                } else if model.searchingDescendants && entries.isEmpty {
                    ProgressView("正在搜索…").controlSize(.small).allowsHitTesting(false)
                } else if model.smartSearchStopped && entries.isEmpty {
                    ContentUnavailableView("搜索已停止", systemImage: "magnifyingglass")
                } else if entries.isEmpty {
                    if model.quickSearchFilters.isActive {
                        ContentUnavailableView("没有符合筛选条件的文件", systemImage: "magnifyingglass")
                            .allowsHitTesting(false)
                    } else if model.query.isEmpty {
                        if model.isStash {
                            ContentUnavailableView("拖入文件或文件夹", systemImage: "tray.and.arrow.down")
                                .allowsHitTesting(false)
                        } else {
                            ContentUnavailableView(model.smartFolder == nil ? "空文件夹" : "没有匹配的文件", systemImage: "folder").allowsHitTesting(false)
                        }
                    } else {
                        ContentUnavailableView.search(text: model.query).allowsHitTesting(false)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if showsHeader || model.isVirtual { paneHeader }
                if !model.isVirtual {
                    BrowserNavigation(workspace: workspace, model: model, isActive: isActive,
                                      focusFileList: focusFileList)
                }
                if !model.isVirtual, model.zipArchive == nil, model.presentsSearch || model.hasSearch { searchControls(model) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.zipArchive == nil { status }
        }
        .overlay {
            if dropHint != nil {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
            }
        }
        .onAppear {
            model.start()
            if isActive && !model.presentsSearch { focusFileList() }
        }
        .onChange(of: model.viewMode) { if isActive && !model.presentsSearch { focusFileList() } }
        .onChange(of: workspace.paneFocusRequest) { if isActive { focusFileList() } }
        .onChange(of: model.directory) {
            dropHint = nil
            workspace.followLinkedNavigation(from: model)
        }
        .onChange(of: model.isStash ? workspace.stash : []) { model.refreshIfStarted() }
        .onChange(of: workspace.searchDirectories(for: model.id)) { model.refreshWorkspaceSearch() }
    }

    private var paneHeader: some View {
        Button {
            workspace.activatePane(model)
            focusFileList()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isStash ? "tray" : "rectangle")
                Text(model.isVirtual ? model.directoryName : "面板 \(number)")
                Spacer(minLength: 0)
            }
            .font(.caption.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(isActive ? Color.accentColor.opacity(0.09) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .background(.bar)
    }

    private func focusFileList() { fileListFocusRequest += 1 }

    private func indicateDrop(_ hint: FileDropHint?) {
        if dropHint != hint { dropHint = hint }
    }

    private func searchControls(_ model: BrowserModel) -> some View {
        let roots = model.searchDirectories.map(\.path)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { scopePicker(model); searchFilters(model) }
                    VStack(alignment: .leading, spacing: 6) { scopePicker(model); searchFilters(model) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(roots.first.map { roots.count == 1 ? $0 : "\($0) 等 \(roots.count) 个目录" } ?? "")
                        .lineLimit(1).truncationMode(.middle)
                        .help(roots.joined(separator: "\n"))
                        .accessibilityLabel("搜索目录 " + roots.joined(separator: "，"))
                    Spacer(minLength: 0)
                    if model.searchingDescendants {
                        ProgressView().controlSize(.mini)
                        Button("停止", action: model.stopFolderSearch)
                    } else if let notice = model.searchNotice {
                        Text(notice).lineLimit(1).help(notice)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
        }
        .background(.bar)
    }

    private func scopePicker(_ model: BrowserModel) -> some View {
        Picker("搜索范围", selection: Binding(get: { model.searchScope }, set: { scope in
            workspace.activatePane(model)
            model.searchScope = scope
        })) {
            ForEach(FolderSearchScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("搜索范围")
    }

    private func searchFilters(_ model: BrowserModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Picker("文件类型", selection: $model.quickSearchFilters.kind) {
                ForEach(SearchFileKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .accessibilityLabel("文件类型")
            Picker("修改日期", selection: $model.quickSearchFilters.date) {
                ForEach(QuickSearchDate.allCases) { date in Text(date.rawValue).tag(date) }
            }
            .accessibilityLabel("修改日期")
            if model.quickSearchFilters.isActive {
                Button("清除筛选", systemImage: "xmark.circle") { model.quickSearchFilters = .init() }
                    .labelStyle(.iconOnly)
                    .help("清除筛选")
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var status: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                Spacer(minLength: 12)
                if let scanned = model.smartSearchScanned {
                    if scanned == 0 {
                        Text("正在搜索…")
                    } else {
                        Text("已扫描 \(scanned) 项")
                    }
                    Button("停止搜索") { model.stopSmartSearch() }
                } else if model.smartSearchStopped {
                    Text("搜索已停止")
                    Button("重新搜索") { model.refresh() }
                } else if model.smartFolder != nil, let notice = model.searchNotice {
                    Label(notice, systemImage: "exclamationmark.circle").lineLimit(1).help(notice)
                } else if let dropHint {
                    Text(dropHint.title)
                        .lineLimit(1)
                        .help(dropHint.directory?.path ?? dropHint.title)
                        .foregroundStyle(Color.accentColor)
                } else if let job = workspace.transfers.active {
                    Button {
                        workspace.revealOperations(.transfers)
                    } label: {
                        Label(job.state == .conflicts ? "有同名项目待处理"
                               : "\(job.request.operation.title) \(job.processed)/\(job.total)",
                              systemImage: job.state == .conflicts ? "exclamationmark.circle" : "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                } else if let workflow = workspace.runningWorkflow {
                    ProgressView().controlSize(.mini)
                    Text("正在运行「\(workflow)」…").lineLimit(1)
                } else if workspace.isTransferring || model.busy {
                    ProgressView().controlSize(.mini)
                    Text("正在处理…")
                } else if !model.selectedIDs.isEmpty {
                    Text(model.selectionSummary)
                } else {
                    Text(model.hasSearch ? "\(model.visibleEntries.count) 项匹配" : "\(model.entries.count) 项")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 13)
            .frame(height: 31)
            .background(.bar)
        }
    }
}

private struct FileViewMenu: View {
    @Bindable var model: BrowserModel
    let workspace: BrowserWorkspace

    var body: some View {
        Menu {
            Section("布局") {
                Picker("布局", selection: $model.viewMode) {
                    ForEach(FileViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.inline)
            }
            if model.viewMode == .details {
                Section("分组") {
                    Picker("分组", selection: $model.grouping) {
                        ForEach(FileGrouping.allCases) { grouping in Text(grouping.rawValue).tag(grouping) }
                    }
                    .pickerStyle(.inline)
                }
                Section("详情列表") {
                    Toggle("紧凑模式", isOn: $model.viewSettings.compactRows)
                    ForEach(FileColumn.allCases.filter { $0 != .name }, id: \.self) { column in
                        Toggle("显示\(column.rawValue)列", isOn: Binding(
                            get: { !model.viewSettings.hiddenColumns.contains(column) },
                            set: { visible in
                                if visible { model.viewSettings.hiddenColumns.remove(column) }
                                else { model.viewSettings.hiddenColumns.insert(column) }
                            }
                        ))
                    }
                    Button("还原列宽") { model.viewSettings.columnWidths.removeAll() }
                        .disabled(model.viewSettings.columnWidths.isEmpty)
                    Button("还原列顺序") { model.viewSettings.columnOrder = nil }
                        .disabled(model.viewSettings.columnOrder == nil)
                }
            } else {
                Section("排序") {
                    Picker("排序", selection: Binding(get: { model.sortColumn },
                           set: { model.sort(by: $0, ascending: model.ascending) })) {
                        ForEach(FileColumn.allCases, id: \.self) { column in Text(column.rawValue).tag(column) }
                    }
                    .pickerStyle(.inline)
                    Toggle("升序", isOn: Binding(get: { model.ascending },
                           set: { model.sort(by: model.sortColumn, ascending: $0) }))
                }
            }
            Section("显示") {
                Toggle("显示文件扩展名", isOn: $model.viewSettings.showExtensions)
                Toggle("显示隐藏文件", isOn: Binding(get: { workspace.showHidden }, set: workspace.setShowHidden))
            }
            Section("选择") {
                Toggle("显示项目复选框", isOn: Binding(
                    get: { model.viewSettings.showsSelectionCheckboxes == true },
                    set: { model.viewSettings.showsSelectionCheckboxes = $0 }
                ))
                Button("全选当前结果", action: model.selectAllResults).disabled(model.visibleEntries.isEmpty)
                Button("反向选择", action: model.invertSelection).disabled(model.visibleEntries.isEmpty)
            }
        } label: {
            Label("视图", systemImage: model.viewMode == .details ? "list.bullet" : "square.grid.2x2")
        }
        .help("切换视图和文件显示设置")
    }
}

private struct PromptView: View {
    let prompt: FilePrompt
    let submit: (String, NewFileFormat?) -> Void
    @ViewState private var text: String
    @ViewState private var format: NewFileFormat?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(prompt: FilePrompt, submit: @escaping (String, NewFileFormat?) -> Void) {
        self.prompt = prompt
        self.submit = submit
        _text = State(initialValue: prompt.initial)
        if case .newFile(let format) = prompt.kind { _format = State(initialValue: format) }
    }

    private var trashCount: Int? {
        if case .trash(let items) = prompt.kind { return items.count }
        return nil
    }

    private var isTrash: Bool { trashCount != nil }

    private var confirmTitle: String {
        if isTrash { return "移到废纸篓" }
        if format != nil { return "创建" }
        return "确定"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(prompt.title, systemImage: isTrash ? "trash" : format != nil ? "doc.badge.plus" : "folder")
                .font(.title3.weight(.semibold))
            if let trashCount {
                Text(trashCount == 1 ? "将「\(prompt.initial)」移到废纸篓？" : "将选中的 \(trashCount) 项移到废纸篓？")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Form {
                    if format != nil {
                        Picker("格式", selection: $format) {
                            ForEach(NewFileFormat.groups, id: \.title) { group in
                                Section(group.title) {
                                    ForEach(group.formats) { option in
                                        Text(option.label).tag(Optional(option))
                                    }
                                }
                            }
                        }
                    }
                    TextField("名称", text: $text, prompt: Text("未命名"))
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                }
                .formStyle(.columns)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: isTrash ? .destructive : nil) {
                    dismiss()
                    submit(text, format)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isTrash && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 410)
        .onAppear { if !isTrash { fieldFocused = true } }
    }
}
