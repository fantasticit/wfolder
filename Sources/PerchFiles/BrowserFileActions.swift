import AppKit

@MainActor
struct BrowserFileActions {
    let model: BrowserModel
    let workspace: BrowserWorkspace

    func activate() { workspace.activatePane(model) }

    func open(_ entry: FileEntry) {
        if model.isVirtual, entry.isFolder { workspace.navigateToFolder(entry.url) }
        else if !entry.isFolder, ZipContents.supports(entry.url) { workspace.openArchivePane(entry) }
        else { model.openEntry(entry) }
    }

    func configureDrop(in scroll: FileDropScrollView, folderAt: @escaping (NSPoint) -> URL?) {
        scroll.registerForDraggedTypes([.fileURL, ArchiveDrag.pasteboardType])
        if model.isStash {
            scroll.storeInStash = { workspace.storeInStash($0) }
        } else {
            scroll.canReceive = { model.canQueueTransfer }
            scroll.destination = { folderAt($0) ?? model.directory }
            scroll.receiveArchive = { archive, directory in
                guard model.canQueueTransfer, !model.busy, !workspace.isTransferring, let entry = archive.archiveEntry() else { return false }
                model.extractZip(entry, paths: archive.members, folder: archive.folder, into: directory) { _ in }
                return true
            }
            scroll.receive = { urls, directory, operation, fromStash in
                workspace.transfer(urls, into: directory, operation: operation, fromStash: fromStash)
            }
        }
    }

    func activateForTabNavigation() {
        guard let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 48,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }
        activate()
    }

    func handleShortcut(_ event: NSEvent, items: @autoclosure () -> [FileEntry]) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if workspace.windowsKeyBindings, modifiers == .option {
            switch event.keyCode {
            case 123: model.back(); return true
            case 124: model.forward(); return true
            case 126:
                if let parent = model.parent { model.navigate(to: parent) }
                return true
            default: break
            }
        }
        guard modifiers == .command || (workspace.windowsKeyBindings && modifiers == .control) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a":
            model.selectAllResults()
        case "c":
            let selected = items()
            guard !selected.isEmpty else { return false }
            model.copy(selected)
        case "x":
            let selected = items()
            guard !selected.isEmpty, model.canQueueTransfer else { return false }
            model.copy(selected, cut: true)
        case "v":
            guard model.canPaste else { return false }
            model.paste()
        default: return false
        }
        return true
    }

    func handleSelectionKey(_ event: NSEvent, entry: @autoclosure () -> FileEntry?) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:
            guard let entry = entry(), workspace.windowsKeyBindings || model.canRenameItems else { return false }
            if workspace.windowsKeyBindings { open(entry) } else { model.askRename(entry) }
        case 120 where workspace.windowsKeyBindings:
            guard let entry = entry(), model.canRenameItems else { return false }
            model.askRename(entry)
        case 96 where workspace.windowsKeyBindings: model.refresh()
        case 49:
            guard let entry = entry() else { return false }
            if entry.isFolder { model.showPreview = true }
            else { model.expandedPreview = entry }
        default: return false
        }
        return true
    }

    func contextualMenu(for items: [FileEntry], showsLocation: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canModify = model.canModifyDirectory
        guard !items.isEmpty else {
            if !model.isVirtual {
                menu.addItem(action("新建文件…", "doc.badge.plus", enabled: canModify) { model.askNewFile() })
                menu.addItem(action("新建文件夹…", "folder.badge.plus", enabled: canModify) { model.askNewFolder() })
                menu.addItem(action("粘贴", "doc.on.clipboard", enabled: model.canPaste) { model.paste() })
                menu.addItem(.separator())
            }
            menu.addItem(action("全选当前结果", enabled: !model.visibleEntries.isEmpty) { model.selectAllResults() })
            menu.addItem(action("反向选择", enabled: !model.visibleEntries.isEmpty) { model.invertSelection() })
            return menu
        }

        let entry = items.count == 1 ? items.first : nil
        if let entry {
            menu.addItem(action("打开", entry.isFolder ? "folder" : "arrow.up.right.square") { open(entry) })
        }
        menu.addItem(openWithMenu(for: items, single: entry))
        if let entry, showsLocation || model.isStash {
            menu.addItem(action("前往所在文件夹", "folder") { workspace.revealInFolder(entry.url) })
        }
        menu.addItem(.separator())
        if !model.isStash {
            menu.addItem(action("剪切", "scissors", enabled: model.canQueueTransfer) { model.copy(items, cut: true) })
        }
        menu.addItem(action("复制", "doc.on.doc") { model.copy(items) })
        if !model.isStash, model.canPaste {
            menu.addItem(action("粘贴到当前文件夹", "doc.on.clipboard") { model.paste() })
        }
        for operation in [PaneTransferOperation.copy, .move] {
            menu.addItem(action("\(operation.title)到…", operation == .copy ? "doc.on.doc" : "arrow.right",
                                enabled: !model.busy) {
                workspace.chooseTransferDestination(operation, items: items, from: model)
            })
        }
        if let entry {
            menu.addItem(action("重命名…", "pencil", enabled: model.canRenameItems) { model.askRename(entry) })
        }
        if model.isStash {
            menu.addItem(action("移出暂存架", "tray.and.arrow.up") { workspace.removeFromStash(items.map(\.url)) })
        } else {
            menu.addItem(action("移到废纸篓…", "trash", enabled: canModify) { model.askTrash(items) })
        }
        menu.addItem(.separator())
        menu.addItem(submenu("更多操作", icon: "ellipsis", items: moreActions(for: items, single: entry)))
        return menu
    }

    private func openWithMenu(for items: [FileEntry], single entry: FileEntry?) -> NSMenuItem {
        let system = NSWorkspace.shared
        var options: [NSMenuItem] = []
        if let entry {
            let defaultURL = system.urlForApplication(toOpen: entry.url)
            let name = defaultURL.map { FileManager.default.displayName(atPath: $0.path) }
            options.append(action(name.map { "默认应用 · \($0)" } ?? "默认应用", "arrow.up.right.square") {
                model.openWithDefaultApp(entry)
            })
            options.append(visualStudioCodeItem(for: items))
            var seen = Set([Bundle.main.bundleIdentifier, "com.microsoft.VSCode",
                            defaultURL.flatMap { Bundle(url: $0)?.bundleIdentifier }].compactMap { $0 })
            let apps = system.urlsForApplications(toOpen: entry.url).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            let compatible = apps.compactMap { app -> NSMenuItem? in
                let identifier = Bundle(url: app)?.bundleIdentifier ?? app.path
                guard seen.insert(identifier).inserted, app != defaultURL else { return nil }
                return action(FileManager.default.displayName(atPath: app.path)) { model.open(items, using: app) }
            }
            if !compatible.isEmpty { options += [.separator()] + compatible }
        } else {
            options.append(action("默认应用") { for item in items { model.openWithDefaultApp(item) } })
            options.append(visualStudioCodeItem(for: items))
        }
        return submenu("打开方式", icon: "arrow.up.right.square", items: options)
    }

    private func moreActions(for items: [FileEntry], single entry: FileEntry?) -> [NSMenuItem] {
        let canModify = model.canModifyDirectory
        var options = [airDropItem(for: items)]
        if let entry {
            options.append(action(entry.isFolder ? "在新标签页中打开" : "快速预览",
                                  entry.isFolder ? "plus.rectangle.on.rectangle" : "eye") {
                if entry.isFolder { workspace.openTab(at: entry.url) }
                else { model.expandedPreview = entry }
            })
            options.append(action("复制路径", "link") { model.copyPath(entry) })
            let pinned = model.isFavorite(entry.url)
            options.append(action(pinned ? "取消固定" : "固定到快速访问", pinned ? "pin.slash" : "pin") {
                model.toggleFavorite(entry.url, isFolder: entry.isFolder)
            })
            if model.isStash, ZipContents.supports(entry.url), !entry.isFolder {
                options.append(action("浏览 ZIP", "archivebox") { open(entry) })
            }
        } else if !model.isStash {
            options.append(action("批量重命名…", "pencil", enabled: canModify) {
                workspace.presentedTool = .batchRename(model, items)
            })
        }
        let urls = items.map(\.url)
        let targets = workspace.transferTargets(from: model)
        if !targets.isEmpty {
            let transfers = NSMenu()
            addTransfer(.copy, targets: targets, urls: urls, to: transfers)
            addTransfer(.move, targets: targets, urls: urls, to: transfers)
            options += transfers.items
            transfers.removeAllItems()
        }
        if !model.isStash {
            options.append(action("加入暂存架", "tray.and.arrow.down") { workspace.storeInStash(urls) })
            if let entry {
                options.append(action("制作副本", "plus.square.on.square", enabled: canModify) { model.duplicate(entry) })
                if entry.cloudStatus == .online {
                    options.append(action("下载到本机", "icloud.and.arrow.down") {
                        do { try FileManager.default.startDownloadingUbiquitousItem(at: entry.url); model.refresh() }
                        catch { model.issue = BrowserIssue(title: "无法下载文件", message: error.localizedDescription) }
                    })
                }
                if !entry.isFolder, FileArchive.canExtract(entry.url) {
                    options.append(action("解压到当前文件夹", "archivebox.fill", enabled: canModify) { model.extract(entry) })
                }
            }
            options.append(action("压缩为 ZIP", "archivebox", enabled: canModify) { model.compress(items) })
        }
        options.append(action("全选当前结果") { model.selectAllResults() })
        options.append(action("反向选择") { model.invertSelection() })
        return options
    }

    private func submenu(_ title: String, icon: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        parent.submenu = menu
        return parent
    }

    private func visualStudioCodeItem(for items: [FileEntry]) -> NSMenuItem {
        action("在 Visual Studio Code 中打开", "chevron.left.forwardslash.chevron.right") {
            model.openInVisualStudioCode(items)
        }
    }

    private func airDropItem(for items: [FileEntry]) -> NSMenuItem {
        action("隔空投送…", "airdrop") { model.sendViaAirDrop(items) }
    }

    private func addTransfer(_ operation: PaneTransferOperation, targets: [BrowserWorkspace.TransferTarget],
                             urls: [URL], to menu: NSMenu) {
        let icon = operation == .copy ? "doc.on.doc" : "arrow.right"
        let enabled = targets.contains { !model.busy && $0.accepts(urls, operation: operation) }
        let items = targets.map { target in
            action(target.title, enabled: !model.busy && target.accepts(urls, operation: operation)) {
                workspace.transfer(urls, into: target.browser.directory, operation: operation, fromStash: model.isStash)
            }
        }
        if let target = targets.first, targets.count == 1 {
            menu.addItem(action("\(operation.title)到面板 \(target.number)", icon, enabled: enabled) {
                workspace.transfer(urls, into: target.browser.directory, operation: operation, fromStash: model.isStash)
            })
        } else {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for item in items { submenu.addItem(item) }
            let parent = NSMenuItem(title: "\(operation.title)到面板", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            parent.submenu = submenu
            parent.isEnabled = enabled
            menu.addItem(parent)
        }
    }

    private func action(_ title: String, _ icon: String? = nil, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = FileMenuItem(title: title, handler: handler)
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        item.isEnabled = enabled
        return item
    }
}

private final class FileMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("FileMenuItem is created in code") }

    @objc private func invoke() { handler() }
}
