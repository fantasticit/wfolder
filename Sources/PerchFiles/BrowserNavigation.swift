import AppKit
import SwiftUI

enum BrowserAddress: Sendable {
    case folder(URL)
    case file(URL)

    static func resolve(_ input: String, relativeTo directory: URL) -> Self? {
        guard !input.isEmpty, !input.utf8.contains(0) else { return nil }
        let url: URL
        if input.hasPrefix("file://") {
            guard let fileURL = URL(string: input), fileURL.isFileURL,
                  fileURL.host == nil || fileURL.host == "" || fileURL.host == "localhost",
                  !fileURL.path.utf8.contains(0) else { return nil }
            url = fileURL
        } else {
            let path = (input as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: path, isDirectory: false, relativeTo: directory)
        }
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return nil }
        let resolved = URL(fileURLWithPath: target.path, isDirectory: isDirectory.boolValue)
        return isDirectory.boolValue ? .folder(resolved) : .file(resolved)
    }
}

struct BrowserTabs: View {
    let workspace: BrowserWorkspace

    var body: some View {
        HStack(spacing: 7) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs) { tab in
                            tabButton(tab).id(tab.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minHeight: 40)
                }
                .scrollIndicators(.hidden)
                .onChange(of: workspace.activeTab.id, initial: true) {
                    proxy.scrollTo(workspace.activeTab.id)
                }
            }
            Button { workspace.openTab() } label: {
                Label("新建标签页", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("新建标签页（⌘T）")
            .padding(.trailing, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标签页")
    }

    private func tabButton(_ tab: BrowserWorkspace.Tab) -> some View {
        let active = workspace.activeTab.id == tab.id
        return HStack(spacing: 2) {
            Button { workspace.selectTab(tab.id) } label: {
                Label(tab.title ?? tab.focusedBrowser.directoryName,
                      systemImage: tab.browsers.count > 1 ? "rectangle.split.2x1" : "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
                    .frame(minWidth: 66, maxWidth: 150, alignment: .leading)
                    .padding(.leading, 9)
                    .padding(.trailing, workspace.tabs.count == 1 ? 9 : 4)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            .help(tab.focusedBrowser.isStash ? tab.focusedBrowser.directoryName : tab.focusedBrowser.directory.path)

            if workspace.tabs.count > 1 {
                Button { workspace.closeTab(tab.id) } label: {
                    Label("关闭标签页 \(tab.title ?? tab.focusedBrowser.directoryName)", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 21, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.trailing, 3)
                .help("关闭标签页")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .contextMenu {
            Button("在新标签页中打开") { workspace.openTab(at: tab.focusedBrowser.directory) }
            if workspace.tabs.count > 1 {
                Button("关闭标签页") { workspace.closeTab(tab.id) }
            }
        }
    }
}

struct BrowserNavigation: View {
    let workspace: BrowserWorkspace
    let model: BrowserModel
    let isActive: Bool
    let focusFileList: () -> Void

    @ViewState private var editing = false
    @ViewState private var draft = ""
    @ViewState private var focusRequest = 0
    @ViewState private var invalidPath = false
    @ViewState private var validation: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                navigationButtons
                addressBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if invalidPath {
                Label("找不到此文件或文件夹，请检查路径。", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            Divider()
        }
        .background(.bar)
        .onChange(of: workspace.addressFocusRequest) { if isActive { beginEditing() } }
        .onChange(of: isActive) { if !isActive { endEditing() } }
        .onChange(of: model.directory) { endEditing() }
        .onDisappear { validation?.cancel() }
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            navigationButton("后退", symbol: "chevron.left", help: "后退（⌘[）",
                             enabled: model.zipArchive != nil || !model.backStack.isEmpty, action: model.back)
            navigationButton("前进", symbol: "chevron.right", help: "前进（⌘]）",
                             enabled: !model.forwardStack.isEmpty, action: model.forward)
            navigationButton("上一级", symbol: "arrow.up", help: "上一级（⌘↑）", enabled: model.parent != nil) {
                if let parent = model.parent { model.navigate(to: parent) }
            }
        }
    }

    private func navigationButton(_ title: String, symbol: String, help: String,
                                  enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            workspace.activatePane(model)
            action()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 26)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    private var addressBar: some View {
        HStack(spacing: 5) {
            Image(systemName: model.parent == nil ? "internaldrive" : "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if editing {
                AddressField(text: Binding(get: { draft }, set: { newValue in
                    draft = newValue
                    validation?.cancel()
                    validation = nil
                    invalidPath = false
                }), focusRequest: focusRequest, submit: submitAddress, blur: endEditing, cancel: {
                    endEditing()
                    focusFileList()
                })
                if validation != nil { ProgressView().controlSize(.mini) }
            } else {
                breadcrumbs
                Button(action: beginEditing) {
                    Label("编辑地址", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .frame(width: 19, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("编辑地址（⌘L）")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 29)
        .background {
            if editing {
                addressBackground
            } else {
                Button(action: beginEditing) {
                    addressBackground.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(editing ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("位置")
    }

    private var addressBackground: some View {
        RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.45))
    }

    private var breadcrumbs: some View {
        let path = model.crumbs
        let ancestors = Array(path.dropLast())
        return ViewThatFits(in: .horizontal) {
            crumbs(visible: ancestors, overflow: [], truncate: false)
            if ancestors.count > 1 {
                crumbs(visible: Array(ancestors.suffix(1)), overflow: Array(ancestors.dropLast()), truncate: false)
            }
            crumbs(visible: [], overflow: ancestors, truncate: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func crumbs(visible: [URL], overflow: [URL], truncate: Bool) -> some View {
        HStack(spacing: 5) {
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow, id: \.path) { url in
                        Button(BrowserModel.placeName(for: url)) { navigate(to: url) }
                    }
                } label: {
                    Label("更上级的文件夹", systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                separator
            }
            ForEach(visible, id: \.path) { url in
                Button(BrowserModel.placeName(for: url)) { navigate(to: url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(url.path)
                separator
            }
            Button(action: beginEditing) {
                Text(model.directoryName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: !truncate, vertical: false)
            }
            .buttonStyle(.plain)
            .help(model.directory.path)
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func navigate(to url: URL) {
        workspace.activatePane(model)
        model.navigate(to: url)
    }

    private func beginEditing() {
        workspace.activatePane(model)
        if !editing { draft = model.directory.path }
        invalidPath = false
        editing = true
        focusRequest += 1
    }

    private func endEditing() {
        validation?.cancel()
        validation = nil
        invalidPath = false
        editing = false
    }

    private func submitAddress() {
        validation?.cancel()
        let input = draft
        let browser = model
        let directory = browser.directory
        validation = Task {
            let address = await Task.detached(priority: .userInitiated) {
                BrowserAddress.resolve(input, relativeTo: directory)
            }.value
            guard !Task.isCancelled, workspace.activeBrowser === browser, browser.directory == directory else { return }
            validation = nil
            if let address {
                endEditing()
                switch address {
                case .folder(let url): browser.navigate(to: url)
                case .file(let url):
                    browser.revealItem(at: url)
                    browser.showPreview = true
                }
                focusFileList()
            } else {
                invalidPath = true
                focusRequest += 1
            }
        }
    }
}

private struct AddressField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let submit: () -> Void
    let blur: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.placeholderString = "输入文件或文件夹路径"
        field.setAccessibilityLabel("地址栏")
        field.delegate = context.coordinator
        context.coordinator.monitorClicks(outside: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard coordinator?.focusRequest == focusRequest, field?.window != nil else { return }
                field?.selectText(nil)
            }
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.stopMonitoring()
        coordinator.focusRequest = nil
        field.delegate = nil
        if let window = field.window, let editor = field.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var focusRequest: Int?
        private weak var field: NSTextField?
        private var mouseMonitor: Any?

        init(parent: AddressField) { self.parent = parent }

        func monitorClicks(outside field: NSTextField) {
            self.field = field
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: nil)
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let field = self.field, let window = field.window else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                if event.window !== window || !field.bounds.insetBy(dx: -8, dy: -5).contains(point) {
                    self.dismissAfterEvent()
                }
                return event
            }
        }

        func stopMonitoring() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            NotificationCenter.default.removeObserver(self)
            field = nil
        }

        @objc private func windowResignedKey(_ notification: Notification) {
            if let window = field?.window, notification.object as? NSWindow === window { dismissAfterEvent() }
        }

        private func dismissAfterEvent() {
            // Allow the clicked control to handle the original event.
            DispatchQueue.main.async { [weak self] in
                if let self, self.field?.window != nil { self.parent.blur() }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) { dismissAfterEvent() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
                return true
            default:
                return false
            }
        }
    }
}
