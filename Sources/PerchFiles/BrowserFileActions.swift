import AppKit

@MainActor
struct BrowserFileActions {
    let model: BrowserModel
    let workspace: BrowserWorkspace

    func activate() { workspace.activatePane(model) }

    func open(_ entry: FileEntry) {
        if model.isStash, entry.isFolder { workspace.navigateToFolder(entry.url) }
        else { model.openEntry(entry) }
    }

    func configureDrop(in scroll: FileDropScrollView, folderAt: @escaping (NSPoint) -> URL?) {
        scroll.registerForDraggedTypes([.fileURL])
        if model.isStash {
            scroll.storeInStash = { workspace.storeInStash($0) }
        } else {
            scroll.canReceive = { model.canQueueTransfer }
            scroll.destination = { folderAt($0) ?? model.directory }
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
        guard event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
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
            guard let entry = entry(), model.canRenameItems else { return false }
            model.askRename(entry)
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
        if model.isStash { return stashMenu(for: items, menu: menu) }
        guard !items.isEmpty else {
            menu.addItem(action("新建文件…", "doc.badge.plus", enabled: canModify) { self.model.askNewFile() })
            menu.addItem(action("新建文件夹…", "folder.badge.plus", enabled: canModify) { self.model.askNewFolder() })
            menu.addItem(.separator())
            menu.addItem(action("粘贴", "doc.on.clipboard", enabled: model.canPaste) { self.model.paste() })
            return menu
        }
        let entry = items.count == 1 ? items.first : nil
        if let entry {
            menu.addItem(action("打开", entry.isFolder ? "folder" : "arrow.up.right.square") { self.open(entry) })
            if !entry.isFolder, ZipContents.supports(entry.url) {
                menu.addItem(action("用默认应用打开", "arrow.up.right.square") { model.openWithDefaultApp(entry) })
            }
            if showsLocation {
                menu.addItem(action("前往所在文件夹", "folder") { self.model.showContainingFolder(of: entry) })
            }
            if entry.isFolder {
                menu.addItem(action("在新标签页中打开", "plus.rectangle.on.rectangle") { workspace.openTab(at: entry.url) })
            } else {
                menu.addItem(action("快速预览", "eye") { self.model.expandedPreview = entry })
            }
            menu.addItem(.separator())
            menu.addItem(action("重命名…", "pencil", enabled: canModify) { self.model.askRename(entry) })
        }
        if items.count > 1 {
            menu.addItem(action("批量重命名…", "pencil", enabled: canModify) {
                workspace.presentedTool = .batchRename(model, items)
            })
        }
        menu.addItem(action("加入暂存架", "tray.and.arrow.down") { workspace.storeInStash(items.map(\.url)) })
        menu.addItem(action("剪切", "scissors", enabled: model.canQueueTransfer) { self.model.copy(items, cut: true) })
        menu.addItem(action("复制", "doc.on.doc") { self.model.copy(items) })
        menu.addItem(action("粘贴到当前文件夹", "doc.on.clipboard", enabled: model.canPaste) { self.model.paste() })
        let targets = workspace.transferTargets(from: model)
        if !targets.isEmpty {
            menu.addItem(.separator())
            let urls = items.map(\.url)
            addTransfer(.copy, targets: targets, urls: urls, to: menu)
            addTransfer(.move, targets: targets, urls: urls, to: menu)
        }
        if let entry {
            menu.addItem(action("制作副本", "plus.square.on.square", enabled: canModify) { self.model.duplicate(entry) })
            menu.addItem(action("复制路径", "link") { self.model.copyPath(entry) })
        }
        menu.addItem(.separator())
        menu.addItem(action("压缩为 ZIP", "archivebox", enabled: canModify) { self.model.compress(items) })
        if let entry, !entry.isFolder, FileArchive.canExtract(entry.url) {
            menu.addItem(action("解压到当前文件夹", "archivebox.fill", enabled: canModify) { self.model.extract(entry) })
        }
        if let entry, entry.isFolder {
            let title = model.isFavorite(entry.url) ? "取消收藏" : "添加到收藏"
            menu.addItem(action(title, model.isFavorite(entry.url) ? "star.slash" : "star") { self.model.toggleFavorite(entry.url) })
        }
        menu.addItem(.separator())
        menu.addItem(action("移到废纸篓…", "trash", enabled: canModify) { self.model.askTrash(items) })
        return menu
    }

    private func stashMenu(for items: [FileEntry], menu: NSMenu) -> NSMenu {
        let urls = items.map(\.url)
        if let entry = items.count == 1 ? items.first : nil {
            if entry.isFolder {
                menu.addItem(action("打开文件夹", "folder") { open(entry) })
            } else {
                menu.addItem(action("用默认应用打开", "arrow.up.right.square") { model.openWithDefaultApp(entry) })
                menu.addItem(action("快速预览", "eye") { model.expandedPreview = entry })
                if ZipContents.supports(entry.url) {
                    menu.addItem(action("浏览 ZIP", "archivebox") { open(entry) })
                }
            }
            menu.addItem(action("前往所在文件夹", "folder") { workspace.revealInFolder(entry.url) })
            menu.addItem(action("重命名…", "pencil", enabled: model.canRenameItems) { model.askRename(entry) })
            menu.addItem(action("复制路径", "link") { model.copyPath(entry) })
            menu.addItem(.separator())
        }
        guard !urls.isEmpty else { return menu }
        menu.addItem(action("复制", "doc.on.doc") { model.copy(items) })
        let targets = workspace.transferTargets(from: model)
        if !targets.isEmpty {
            addTransfer(.copy, targets: targets, urls: urls, to: menu)
            addTransfer(.move, targets: targets, urls: urls, to: menu)
        }
        menu.addItem(action("移出暂存架", "tray.and.arrow.up") { workspace.removeFromStash(urls) })
        return menu
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
