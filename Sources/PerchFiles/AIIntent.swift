import SwiftUI

struct AIIntent: Decodable, Sendable {
    enum Action: String, Decodable, Sendable {
        case search, navigate, split, switchPane, view, preview, stash, copy, move
        case compare, organize, workspace, queue, history, searchResults, workflow, answer
    }

    struct Location: Decodable, Sendable {
        enum Place: String, Decodable, Sendable {
            case current, home, desktop, documents, downloads, pictures, applications, delivery, computer
        }

        let place: Place?
        let path: String?

        func input(relativeTo root: URL, projectDelivery: URL? = nil) throws -> String {
            if let path {
                guard place == nil, !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0),
                      !path.contains("://") || path.hasPrefix("file://") else { throw AIActionError.invalidParameters }
                return path
            }
            guard let place else { throw AIActionError.invalidParameters }
            switch place {
            case .current: return root.path
            case .home: return "~"
            case .desktop: return "~/Desktop"
            case .documents: return "~/Documents"
            case .downloads: return "~/Downloads"
            case .pictures: return "~/Pictures"
            case .applications: return "/Applications"
            case .computer: return "/"
            case .delivery:
                guard let projectDelivery else { throw FileWorkflowError.missingDelivery }
                return projectDelivery.path
            }
        }
    }

    struct Filters: Decodable, Sendable {
        enum Kind: String, Decodable, Sendable {
            case folder, image, video, audio, document, archive

            var searchKind: SearchFileKind {
                switch self {
                case .folder: return .folder
                case .image: return .image
                case .video: return .video
                case .audio: return .audio
                case .document: return .document
                case .archive: return .archive
                }
            }
        }

        let filename: String?
        let contents: String?
        let tag: String?
        let extensions: [String]?
        let kind: Kind?
        let minimumMB: Double?
        let days: Int?
        let recursive: Bool?
        let concepts: [[String]]?

        func searchConcepts() throws -> [[String]] {
            guard let concepts else { return [] }
            guard concepts.count <= 5, concepts.allSatisfy({ group in
                (1...8).contains(group.count) && group.allSatisfy {
                    $0.count <= 64 && $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) &&
                    !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                }
            }) else { throw AIActionError.invalidParameters }
            return concepts.map { group in group.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        }

        func conditions(recursiveByDefault: Bool = true) throws -> SearchConditions {
            let suffixes = extensions ?? []
            guard suffixes.count <= 30,
                  suffixes.allSatisfy({ !$0.isEmpty && $0.count <= 20 && $0.range(
                    of: #"^\.?[A-Za-z0-9][A-Za-z0-9_+-]*$"#, options: .regularExpression) != nil }),
                  [filename, contents, tag].compactMap({ $0 }).allSatisfy({ $0.count <= 500 }) else {
                throw AIActionError.invalidParameters
            }
            let result = SearchConditions(
                filename: filename ?? "", contents: contents ?? "", tag: tag ?? "",
                extensions: suffixes.joined(separator: ", "), minimumMB: minimumMB.map { String($0) } ?? "",
                days: days.map { String($0) } ?? "", recursive: recursive ?? recursiveByDefault, kind: kind?.searchKind
            )
            guard result.valid else { throw AIActionError.invalidParameters }
            return result
        }
    }

    enum ViewMode: String, Decodable, Sendable {
        case details, medium, large

        var value: FileViewMode {
            switch self {
            case .details: return .details
            case .medium: return .medium
            case .large: return .large
            }
        }
    }

    enum Rename: String, Decodable, Sendable { case date, prefix }
    enum Grouping: String, Decodable, Sendable { case kind }
    enum WorkflowTransfer: String, Decodable, Sendable { case copy, move }

    let action: Action
    let location: Location?
    let destination: Location?
    let filters: Filters?
    let name: String?
    let project: String?
    let direction: String?
    let view: ViewMode?
    let enabled: Bool?
    let rename: Rename?
    let groupBy: Grouping?
    let previewOnly: Bool?
    let prefix: String?
    let message: String?
    let compress: Bool?
    let transfer: WorkflowTransfer?

    private func address(for location: Location?, in context: AIFolderContext) async throws -> BrowserAddress {
        guard let location else { return .folder(context.directory) }
        let directory = context.directory
        let input = try location.input(relativeTo: directory, projectDelivery: context.projectDelivery)
        let worker = Task.detached(priority: .userInitiated) { BrowserAddress.resolve(input, relativeTo: directory) }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard let result else { throw AIActionError.locationMissing(input) }
        return result
    }

    private func folder(for location: Location?, in context: AIFolderContext) async throws -> URL {
        guard case .folder(let folder) = try await address(for: location, in: context) else {
            throw AIActionError.folderRequired
        }
        return folder
    }

    @MainActor func searchFolder(in workspace: BrowserWorkspace, context: AIFolderContext,
                                prompt: String? = nil) async throws -> SmartFolder {
        let computer = location?.place == .computer || Self.requestsComputerSearch(prompt)
        var root = computer ? URL(fileURLWithPath: "/", isDirectory: true) : try await folder(for: location, in: context)
        var conditions = try filters?.conditions() ?? SearchConditions()
        var concepts = try filters?.searchConcepts() ?? []
        if concepts.isEmpty, conditions.contents.isEmpty, conditions.kind == nil || conditions.kind == .document,
           let prompt, let aliases = SearchSemantics.documentTopic(filename: conditions.filename, requestedBy: prompt) {
            conditions.filename = ""
            conditions.kind = .document
            concepts = [aliases]
        }
        if Self.isAllComputerImages(prompt) {
            conditions = SearchConditions(kind: .image)
            concepts = []
        }
        var scopeID = context.workspaceID
        var scopeName = context.workspaceName
        let namedMemory = project.flatMap { workspace.aiMemory.project(named: $0) }
            ?? workspace.aiMemory.project(mentionedIn: prompt)
        let remembered = namedMemory ?? (project == nil ? workspace.activeProjectMemory : nil)
        if !computer, location == nil, let remembered, let known = workspace.searchRoot(for: remembered) {
            root = try await folder(for: Location(place: nil, path: known.path), in: context)
            scopeID = remembered.id
            scopeName = remembered.name
        } else if !computer, let project {
            let name = project.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count <= 64, name.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
                  (try? FileSystem.validateName(name)) != nil,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw AIActionError.invalidParameters
            }
            if location == nil {
                let openFolders = workspace.tabs.flatMap(\.browsers).filter { !$0.isVirtual }.map(\.directory)
                if let found = try await SearchProjectLocation.find(name, current: root,
                                                                   knownRoots: openFolders + workspace.activeBrowser.favorites) {
                    root = found
                }
            }
            if !root.pathComponents.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                concepts.insert([name], at: 0)
            }
        }
        try Task.checkCancellation()
        let feedback = prompt.map {
            SearchMemoryContext(query: $0, root: root, workspaceID: scopeID, workspaceName: scopeName, source: .assistant)
        }
        return SmartFolder(name: shortName ?? "AI 搜索", root: root, conditions: conditions,
                           semantics: concepts.isEmpty ? nil : SearchSemantics(concepts: concepts),
                           feedbackContext: feedback)
    }

    // An explicit fresh search must never be interpreted as replaying an earlier result.
    static func directSearch(for prompt: String) -> AIIntent? {
        guard isAllComputerImages(prompt) else { return nil }
        let json = #"{"action":"search","name":"本机图片","location":{"place":"computer"},"filters":{"kind":"image","recursive":true}}"#
        return try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    static func isAllComputerImages(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        // Match only a complete, unqualified request. Dates, subjects and exclusions
        // must still be interpreted by the model rather than silently discarded.
        let chinese = #"^\s*(?:(?:请|麻烦|帮我|帮忙|我想要|我想|可以|能不能|能否|查找|搜索|搜|查|找|显示|列出|看|一下|下|在)\s*)*(?:本机|全盘|(?:整台|整个|这台|全部|全)电脑|所有磁盘)(?:里|中|上|内|的)*(?:所有|全部)的?(?:图片|图像|照片)(?:文件)?[。.!！?？\s]*$"#
        let english = #"^\s*(?:please\s+)?(?:find|search(?:\s+for)?|show|list)(?:\s+me)?\s+all\s+(?:images|pictures|photos)\s+(?:on|in)\s+(?:this computer|the entire computer|all (?:local )?(?:disks|drives))[.!?\s]*$"#
        return prompt.range(of: chinese, options: .regularExpression) != nil ||
            prompt.range(of: english, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func requestsComputerSearch(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        return prompt.range(of: #"本机(?:里|中|上|内|的|所有|全部)|全(?:部)?电脑|整(?:台电脑|个电脑)|全盘|所有磁盘|(?i:\b(?:this computer|entire (?:computer|machine)|all (?:local )?(?:disks|drives))\b)"#,
                            options: .regularExpression) != nil
    }

    @MainActor func proposal(in workspace: BrowserWorkspace, context: AIFolderContext) async throws -> AIProposal {
        switch action {
        case .answer:
            guard let text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw AIServiceError.response
            }
            return AIProposal(title: String(text.prefix(1500)))
        case .search:
            let search = try await searchFolder(in: workspace, context: context)
            return AIProposal(title: "打开搜索结果面板", details: [search.root.path] + search.conditions.aiDetails,
                              button: "搜索") { workspace.openSmartFolder(search) }
        case .searchResults:
            return AIProposal(title: "这段对话还没有完成的搜索。")
        case .navigate:
            guard location != nil else { throw AIActionError.invalidParameters }
            let target = try await address(for: location, in: context)
            let title: String
            let path: String
            switch target {
            case .folder(let url): title = "前往文件夹"; path = url.path
            case .file(let url): title = "定位并预览文件"; path = url.path
            }
            return AIProposal(title: title, details: [path], button: "前往") { workspace.followAddress(target) }
        case .split:
            let split: PaneSplitDirection
            switch direction {
            case "leftRight": split = .sideBySide
            case "topBottom": split = .stacked
            default: throw AIActionError.invalidParameters
            }
            return AIProposal(title: split == .sideBySide ? "左右分割当前面板" : "上下分割当前面板",
                              button: "分割") { workspace.splitPane(split) }
        case .switchPane:
            guard let direction, let side = PaneDirection(rawValue: direction),
                  workspace.activeTab.layout.neighbor(of: context.paneID, direction: side,
                    proportions: workspace.activeTab.proportions) != nil else { throw AIActionError.paneMissing }
            return AIProposal(title: "切换到\(side.label)侧面板", button: "切换") { workspace.switchPane(toward: side) }
        case .view:
            guard let view, !workspace.activeBrowser.isArchivePane else { throw AIActionError.invalidParameters }
            return AIProposal(title: "切换到\(view.value.rawValue)", button: "切换") {
                workspace.activeBrowser.viewMode = view.value
            }
        case .preview:
            let show = enabled ?? true
            return AIProposal(title: show ? "显示预览面板" : "隐藏预览面板", button: "应用") {
                workspace.activeBrowser.showPreview = show
            }
        case .stash:
            if enabled == true {
                guard !context.files.isEmpty else { throw AIActionError.selectionRequired }
                return AIProposal(title: "将 \(context.files.count) 项加入暂存架",
                                  details: context.selectionDetails, button: "加入") {
                    workspace.storeInStash(context.files)
                    workspace.openStashPane()
                }
            }
            return AIProposal(title: "打开文件暂存架", button: "打开") { workspace.openStashPane() }
        case .copy, .move:
            return try await transferProposal(in: workspace, context: context)
        case .compare:
            guard workspace.folderBrowsers.count >= 2 else { throw AIActionError.twoPanesRequired }
            return AIProposal(title: "打开目录对比", details: ["在对比工具中选择两侧目录并查看同步计划。"],
                              button: "打开对比") { workspace.presentedTool = .compare }
        case .organize:
            return try await organizationProposal(in: workspace, context: context)
        case .workflow:
            return try await workflowProposal(in: workspace, context: context)
        case .workspace:
            guard let name = shortName,
                  let saved = workspace.namedWorkspaces.first(where: {
                      $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                  }) else { throw AIActionError.workspaceMissing }
            return AIProposal(title: "打开工作区「\(saved.name)」", button: "打开") { workspace.openWorkspace(saved) }
        case .queue, .history:
            let queue = action == .queue
            return AIProposal(title: queue ? "打开传输队列" : "打开操作历史", button: "打开") {
                workspace.revealOperations(queue ? .transfers : .history)
            }
        }
    }

    @MainActor private func workflowProposal(in workspace: BrowserWorkspace, context: AIFolderContext) async throws -> AIProposal {
        var draft = FileWorkflow(name: shortName.map { String($0.prefix(80)) } ?? "文件流程",
                                 compresses: compress == true)
        if rename == .date {
            draft.rename = BatchRenameRule(style: .modifiedDate)
        } else if rename == .prefix {
            guard let prefix, !prefix.isEmpty, prefix.count <= 80 else { throw AIActionError.invalidParameters }
            draft.rename = BatchRenameRule(style: .prefix, text: prefix)
        }
        if let transfer {
            draft.transfer = transfer == .copy ? .copy : .move
            if destination?.place == .delivery {
                draft.usesProjectDelivery = true
            } else if let destination {
                draft.destination = try await folder(for: destination, in: context)
            }
        }
        guard draft.hasActions else { throw AIActionError.invalidParameters }
        let browser = workspace.activeBrowser
        let request = FileWorkflowRequest(draft: draft, entries: browser.selectedEntries, browser: browser)
        return AIProposal(title: "查看文件流程「\(draft.name)」", details: [draft.details], button: "查看流程") {
            workspace.workflowRequest = request
        }
    }

    private var shortName: String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(120))
    }

    @MainActor private func transferProposal(in workspace: BrowserWorkspace, context: AIFolderContext) async throws -> AIProposal {
        guard !context.files.isEmpty, context.files.allSatisfy(\.isFileURL), !workspace.activeBrowser.busy else {
            throw AIActionError.selectionRequired
        }
        let operation: PaneTransferOperation = action == .move ? .move : .copy
        let title = "\(operation.title) \(context.files.count) 项"
        if let destination {
            let folder = try await folder(for: destination, in: context)
            return AIProposal(title: title, details: ["目标：\(folder.path)"] + context.selectionDetails,
                              button: operation.title) {
                workspace.transfer(context.files, into: folder, operation: operation, fromStash: workspace.activeBrowser.isStash)
            }
        }
        let targets = workspace.transferTargets(from: workspace.activeBrowser)
            .filter { $0.accepts(context.files, operation: operation) }
        guard !targets.isEmpty else { throw AIActionError.targetRequired }
        if let target = targets.only {
            let folder = target.browser.directory
            return AIProposal(title: title, details: ["目标：\(folder.path)"] + context.selectionDetails,
                              button: operation.title) {
                workspace.transfer(context.files, into: folder, operation: operation, fromStash: workspace.activeBrowser.isStash)
            }
        }
        let choice = BrowserWorkspace.TransferChoice(urls: context.files, operation: operation, targets: targets,
                                                     fromStash: workspace.activeBrowser.isStash)
        return AIProposal(title: title, details: ["接下来选择目标面板。"] + context.selectionDetails,
                          button: "选择目标") { workspace.transferChoice = choice }
    }

    @MainActor private func organizationProposal(in workspace: BrowserWorkspace,
                                                   context: AIFolderContext) async throws -> AIProposal {
        let source = try await folder(for: location, in: context)
        let target = destination == nil ? source : try await folder(for: destination, in: context)
        let conditions = try filters?.conditions(recursiveByDefault: false) ?? SearchConditions(recursive: false)
        var rule = OrganizationRule(name: shortName ?? "AI 整理", source: source, destination: target, conditions: conditions)
        let classify = groupBy == .kind || (destination == nil && rename == nil)
        rule.groupsByKind = classify
        var details = ["来源：\(source.path)", "目标：\(target.path)"]
        if classify { details.append("按文件类型归入子文件夹，同名跳过") }
        if rename == .date {
            rule.renaming = true
            rule.rename.style = .modifiedDate
            details.append("按修改日期添加前缀")
        } else if rename == .prefix {
            guard let prefix, !prefix.isEmpty, prefix.count <= 80, !prefix.contains("/"), !prefix.contains(":"),
                  !prefix.utf8.contains(0) else { throw AIActionError.invalidParameters }
            rule.renaming = true
            rule.rename.style = .prefix
            rule.rename.text = prefix
            details.append("添加文件名前缀「\(prefix)」")
        }
        return AIProposal(title: "整理文件", details: details + conditions.aiDetails, button: "查看整理方案",
                          organizationRule: previewOnly == true ? nil : rule) {
            workspace.presentedTool = .organizationDraft(rule)
        }
    }
}

struct AIFolderContext: Sendable {
    let tabID: UUID
    let paneID: UUID
    let directory: URL
    let files: [URL]
    let workspaceID: UUID?
    let workspaceName: String?
    let projectDelivery: URL?
    private let browserDirectory: URL

    @MainActor init(_ workspace: BrowserWorkspace) {
        tabID = workspace.activeTab.id
        workspaceID = workspace.activeTab.namedWorkspaceID
        workspaceName = workspaceID.flatMap { id in workspace.namedWorkspaces.first { $0.id == id }?.name }
        projectDelivery = workspace.activeProjectMemory?.delivery
        paneID = workspace.activeBrowser.id
        browserDirectory = workspace.activeBrowser.directory
        directory = workspace.activeBrowser.smartFolder?.root ?? workspace.directoryBrowser?.directory ?? browserDirectory
        files = workspace.activeBrowser.selectedEntries.map(\.url)
    }

    @MainActor func matches(_ workspace: BrowserWorkspace) -> Bool {
        tabID == workspace.activeTab.id && paneID == workspace.activeBrowser.id &&
            workspaceID == workspace.activeTab.namedWorkspaceID && projectDelivery == workspace.activeProjectMemory?.delivery &&
            browserDirectory == workspace.activeBrowser.directory &&
            directory == (workspace.activeBrowser.smartFolder?.root ?? workspace.directoryBrowser?.directory ??
                          workspace.activeBrowser.directory) &&
            Set(files) == workspace.activeBrowser.selectedIDs
    }

    var selectionDetails: [String] {
        var names = files.prefix(5).map(\.lastPathComponent)
        if files.count > names.count { names.append("另有 \(files.count - names.count) 项") }
        return names
    }
}

@MainActor struct AIProposal {
    let title: String
    var details: [String] = []
    var button: String? = nil
    var organizationRule: OrganizationRule? = nil
    var apply: (() -> Void)? = nil
}

enum AIActionError: LocalizedError {
    case invalidParameters, locationMissing(String), folderRequired, paneMissing, selectionRequired,
         twoPanesRequired, workspaceMissing, targetRequired, contextChanged, ambiguousProject(String),
         projectLookupNeedsAccess(String), projectNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidParameters: return "操作参数不完整。请补充要操作的内容后重试。"
        case .locationMissing(let path): return "找不到路径「\(path)」。请检查名称或输入完整路径。"
        case .folderRequired: return "请指定一个文件夹。"
        case .paneMissing: return "对应方向没有可切换的面板。"
        case .selectionRequired: return "请先在文件列表或网格里选中要操作的文件。"
        case .twoPanesRequired: return "目录对比需要两个文件夹面板。"
        case .workspaceMissing: return "找不到这个工作区。请使用已保存的工作区名称。"
        case .targetRequired: return "请在指令里写明目标文件夹，或先打开另一个目录面板。"
        case .contextChanged: return "当前面板或选区已改变，请重新分析。"
        case .ambiguousProject(let name): return "找到多个名为「\(name)」的项目。请指定要搜索的文件夹路径。"
        case .projectLookupNeedsAccess(let name): return "无法读取「文稿」来定位项目「\(name)」。请在 wfolder 中选取项目文件夹后重试。"
        case .projectNotFound(let name): return "没有定位到项目「\(name)」。请指定要搜索的文件夹路径。"
        }
    }
}

extension SearchConditions {
    var aiDetails: [String] {
        var details: [String] = []
        if !filename.isEmpty { details.append("文件名含「\(filename)」") }
        if !contents.isEmpty { details.append("内容含「\(contents)」") }
        if !tag.isEmpty { details.append("标签含「\(tag)」") }
        if !extensions.isEmpty { details.append("扩展名 \(extensions)") }
        if let kind, kind != .any { details.append("类型 \(kind.rawValue)") }
        if !minimumMB.isEmpty { details.append("大小至少 \(minimumMB) MB") }
        if !days.isEmpty { details.append("最近 \(days) 天有修改") }
        details.append(recursive ? "包含子目录" : "仅当前目录")
        return details
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
