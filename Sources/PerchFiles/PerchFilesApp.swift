import SwiftUI

extension Notification.Name {
    static let focusFileSearch = Self("PerchFiles.focusFileSearch")
}

private struct BrowserFocus: FocusedValueKey {
    typealias Value = BrowserWorkspace
}

extension FocusedValues {
    var browserWorkspace: BrowserWorkspace? {
        get { self[BrowserFocus.self] }
        set { self[BrowserFocus.self] = newValue }
    }
}

@main
enum PerchFilesEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--mcp" {
            AgentMCP.run()
        } else {
            PerchFilesApp.main()
        }
    }
}

struct PerchFilesApp: App {
    @NSApplicationDelegateAdaptor(PerchDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("wfolder", id: "browser") {
            BrowserView(directory: Self.startingDirectory, restoresSession: Self.startingDirectory == nil) {
                delegate.showBrowserWindow = { openWindow(id: "browser") }
                delegate.attachWorkspace($0)
            }
            .frame(minWidth: 920, minHeight: 510)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_170, height: 720)
        .commands { BrowserCommands() }

        Settings {
            TabView {
                BrowserGeneralSettings()
                    .tabItem { Label("通用", systemImage: "gearshape") }
                DefaultOpeningSettingsView()
                    .tabItem { Label("默认打开", systemImage: "folder") }
                AISettingsView()
                    .tabItem { Label("AI 服务", systemImage: "sparkles") }
                AIPermissionsView()
                    .tabItem { Label("AI 权限", systemImage: "lock.shield") }
                AIMemorySettingsView()
                    .tabItem { Label("AI 记忆", systemImage: "brain") }
                AgentConnectionsView()
                    .tabItem { Label("Agent 连接", systemImage: "link") }
            }
            .fixedSize()
        }
    }

    private static var startingDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--folder"), arguments.indices.contains(flag + 1) else {
            return nil
        }
        let path = (arguments[flag + 1] as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

@MainActor
final class PerchDelegate: NSObject, NSApplicationDelegate {
    var showBrowserWindow: (() -> Void)?
    private weak var workspace: BrowserWorkspace?
    private var pendingFinderItems: [BrowserAddress] = []

    func attachWorkspace(_ workspace: BrowserWorkspace) {
        self.workspace = workspace
        AgentService.shared.bringForward = { [weak self] in
            guard let self else { return }
            NSApp.activate()
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                self.showBrowserWindow?()
            }
        }
        AgentService.shared.attach(workspace)
        guard !pendingFinderItems.isEmpty else { return }
        let items = pendingFinderItems
        pendingFinderItems.removeAll()
        DispatchQueue.main.async { [weak self] in self?.openFinderItems(items) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receiveExternalURLs(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receiveExternalURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(revealSelection(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAERevealSelection))
    }

    @objc private func revealSelection(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        let values = direct.descriptorType == typeAEList ? (1...max(1, direct.numberOfItems)).compactMap {
            direct.atIndex($0)
        } : [direct]
        let urls = values.compactMap { item -> URL? in
            guard let string = item.coerce(toDescriptorType: typeFileURL)?.stringValue,
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url
        }
        receiveExternalURLs(urls, revealing: true)
    }

    @objc(openInWfolder:userData:error:)
    func openInWfolder(_ pasteboard: NSPasteboard, userData: String?,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else {
            error?.pointee = "找不到 Finder 选中的文件或文件夹。"
            return
        }
        receiveExternalURLs(urls)
    }

    private func receiveExternalURLs(_ urls: [URL], revealing: Bool = false) {
        Task {
            let items = await Task.detached(priority: .userInitiated) {
                urls.compactMap { url -> BrowserAddress? in
                    guard let address = BrowserAddress.resolve(fileURL: url, packagesAsFiles: true) else { return nil }
                    return revealing ? .file(url.standardizedFileURL) : address
                }
            }.value
            if !items.isEmpty { openFinderItems(items) }
        }
    }

    private func openFinderItems(_ items: [BrowserAddress]) {
        guard let workspace, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "browser" }) else {
            pendingFinderItems.append(contentsOf: items)
            showBrowserWindow?()
            return
        }
        workspace.openFinderItems(items)
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, workspace.hasFileMutations else { return .terminateNow }
        workspace.cancelTransfersForQuit()
        Task {
            while workspace.hasFileMutations { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserWorkspace) private var workspace

    private var browser: BrowserModel? { workspace?.activeBrowser }

    private func canTransfer(_ operation: PaneTransferOperation) -> Bool {
        guard let workspace, let browser, !browser.busy, !browser.selectedIDs.isEmpty else { return false }
        let urls = browser.selectedEntries.map(\.url)
        return workspace.transferTargets(from: browser).contains { $0.accepts(urls, operation: operation) }
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建标签页") { workspace?.openTab() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("新建文件…") { browser?.askNewFile() }
                .keyboardShortcut("n")
                .disabled(browser?.canModifyDirectory != true)
            Button("新建文件夹") { browser?.askNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.canModifyDirectory != true)
            Button("打开所选项目") {
                if let workspace, let browser, let entry = browser.selected {
                    BrowserFileActions(model: browser, workspace: workspace).open(entry)
                }
            }
            .keyboardShortcut("o")
            .disabled(browser?.selected == nil)
            Button("隔空投送…") {
                if let browser { browser.sendViaAirDrop(browser.selectedEntries) }
            }
            .disabled(browser?.selectedIDs.isEmpty != false)
            Button("重命名所选项目") {
                if let browser, let entry = browser.selected { browser.askRename(entry) }
            }
            .disabled(browser?.selected == nil || browser?.canRenameItems != true)
            Button("移到废纸篓…") {
                if let browser { browser.askTrash(browser.selectedEntries) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(browser?.selectedIDs.isEmpty != false || browser?.canModifyDirectory != true)
            Divider()
            Button("复制到文件夹…") {
                if let workspace, let browser { workspace.chooseTransferDestination(.copy, items: browser.selectedEntries, from: browser) }
            }
            .disabled(browser?.selectedIDs.isEmpty != false || browser?.busy == true)
            Button("移动到文件夹…") {
                if let workspace, let browser { workspace.chooseTransferDestination(.move, items: browser.selectedEntries, from: browser) }
            }
            .disabled(browser?.selectedIDs.isEmpty != false || browser?.busy == true)
            Button("复制到其他面板") { workspace?.requestTransfer(.copy) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!canTransfer(.copy))
            Button("移动到其他面板") { workspace?.requestTransfer(.move) }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(!canTransfer(.move))
        }
        CommandGroup(replacing: .saveItem) {
            Button("关闭当前面板或标签页") { workspace?.closeFocusedItem() }
                .keyboardShortcut("w")
                .disabled(workspace == nil)
            Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("搜索文件和文件夹") {
                NotificationCenter.default.post(name: .focusFileSearch, object: nil)
            }
            .keyboardShortcut("f")
            .disabled(browser == nil)
        }
        CommandMenu("文件操作") {
            Button("传输队列…") { workspace?.revealOperations(.transfers) }
            Button("Agent 任务…") { AgentService.shared.present() }.disabled(workspace == nil)
                .disabled(workspace == nil)
            Button("操作历史…") { workspace?.revealOperations(.history) }
                .disabled(workspace == nil)
            Button("撤销文件操作") { workspace?.revealOperations(.history); workspace?.undoFileOperation() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(workspace?.canUndoFileOperation != true)
        }
        CommandMenu("工作区") {
            Button("AI 助手…") { workspace?.openAIAssistant() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("保存或打开工作区…") { workspace?.presentedTool = .workspaces }
                .keyboardShortcut("s")
                .disabled(workspace == nil)
            Button("文件暂存架") { workspace?.openStashPane() }
                .disabled(workspace == nil)
            Button("批量重命名…") {
                if let browser, browser.selectedIDs.count > 1, browser.canModifyDirectory {
                    workspace?.presentedTool = .batchRename(browser, browser.selectedEntries)
                }
            }
            .disabled(workspace == nil)
            Button("对比面板目录…") { workspace?.presentedTool = .compare }
                .disabled((workspace?.folderBrowsers.count ?? 0) < 2)
            Divider()
            Button("命令面板…") { workspace?.presentedTool = .commands }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("高级搜索…") { workspace?.presentedTool = .advancedSearch(nil) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("服务器与磁盘…") { workspace?.presentedTool = .remote }
                .disabled(workspace == nil)
            Button("整理规则…") { workspace?.presentedTool = .organization }
                .disabled(workspace == nil)
            Button("Spotlight 搜索…") { workspace?.presentedTool = .spotlight }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(workspace == nil)
        }
        CommandMenu("文件工具") {
            Button("显示文件工具…") {
                guard let workspace else { return }
                workspace.presentedTool = .professional(nil, workspace.activeBrowser.selectedEntries.map(\.url))
            }.disabled(workspace == nil)
            Divider()
            ForEach(ProfessionalPage.allCases) { page in
                Button(page.action + "…") {
                    guard let workspace else { return }
                    if page == .search { workspace.openContentSearch() }
                    else { workspace.presentedTool = .professional(page, workspace.activeBrowser.selectedEntries.map(\.url)) }
                }
                .disabled(workspace == nil)
            }
            Divider()
            Link("查看版本更新…", destination: URL(string: "https://github.com/fantasticit/wfolder/releases")!)
        }
        CommandMenu("前往") {
            Button("后退") {
                if let browser, browser.isArchivePane { workspace?.closeArchivePane(browser) }
                else { browser?.back() }
            }
                .keyboardShortcut("[")
                .disabled(browser?.zipArchive == nil && browser?.backStack.isEmpty != false)
            Button("前进") { browser?.forward() }
                .keyboardShortcut("]")
                .disabled(browser?.forwardStack.isEmpty != false)
            Button("上一级") {
                if let browser, let parent = browser.parent { browser.navigate(to: parent) }
            }
            .keyboardShortcut(.upArrow)
            .disabled(browser?.parent == nil)
            Divider()
            Button("编辑地址") { workspace?.focusAddress() }
                .keyboardShortcut("l")
                .disabled(browser?.isVirtual != false)
            Button("前往路径…") { workspace?.presentedTool = .goToPath }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
        CommandGroup(before: .windowArrangement) {
            Button("下一个标签页") { workspace?.selectAdjacentTab(forward: true) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((workspace?.tabs.count ?? 0) < 2)
            Button("上一个标签页") { workspace?.selectAdjacentTab(forward: false) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((workspace?.tabs.count ?? 0) < 2)
        }
        SidebarCommands()
        CommandGroup(after: .toolbar) {
            Button("左右分割面板") { workspace?.splitPane(.sideBySide) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspace == nil)
            Button("上下分割面板") { workspace?.splitPane(.stacked) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("切换到下一面板") { workspace?.switchPane() }
                .keyboardShortcut("`", modifiers: [.command, .option])
                .disabled((workspace?.activeTab.browsers.count ?? 0) < 2)
            ForEach(PaneDirection.allCases) { direction in
                Button("切换到\(direction.label)侧面板") { workspace?.switchPane(toward: direction) }
                    .keyboardShortcut(direction.key, modifiers: [.control, .option])
                    .disabled((workspace?.activeTab.browsers.count ?? 0) < 2)
            }
            Toggle("Windows 键位", isOn: Binding(
                get: { workspace?.windowsKeyBindings ?? false },
                set: { workspace?.windowsKeyBindings = $0 }
            )).disabled(workspace == nil)
            Button("关闭当前面板") { workspace?.closePane() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(workspace?.canClosePane != true)
            Toggle("预览面板", isOn: Binding(
                get: { browser?.showPreview ?? false },
                set: { browser?.showPreview = $0 }
            ))
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(browser == nil)
            Toggle("显示隐藏文件", isOn: Binding(
                get: { workspace?.showHidden ?? false },
                set: { workspace?.setShowHidden($0) }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
            Button("重新读取") { browser?.refresh() }
                .keyboardShortcut("r")
                .disabled(browser == nil)
        }
    }
}
