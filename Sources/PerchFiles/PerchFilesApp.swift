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
struct PerchFilesApp: App {
    @NSApplicationDelegateAdaptor(PerchDelegate.self) private var delegate

    var body: some Scene {
        Window("wfolder", id: "browser") {
            BrowserView(directory: Self.startingDirectory, restoresSession: Self.startingDirectory == nil) {
                delegate.workspace = $0
            }
            .frame(minWidth: 920, minHeight: 510)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_170, height: 720)
        .commands { BrowserCommands() }
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

final class PerchDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: BrowserWorkspace?

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
                .disabled(workspace == nil)
            Button("操作历史…") { workspace?.revealOperations(.history) }
                .disabled(workspace == nil)
            Button("撤销文件操作") { workspace?.revealOperations(.history); workspace?.undoFileOperation() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(workspace?.canUndoFileOperation != true)
        }
        CommandMenu("工作区") {
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
            Button("Spotlight 搜索…") { workspace?.presentedTool = .spotlight }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(workspace == nil)
        }
        CommandMenu("前往") {
            Button("后退") { browser?.back() }
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
                .disabled(browser?.isStash != false)
            Button("前往文件夹…") { workspace?.focusAddress() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser?.isStash != false)
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
