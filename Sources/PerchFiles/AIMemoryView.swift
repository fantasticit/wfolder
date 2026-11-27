import SwiftUI

struct AIMemorySettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case feedback = "搜索反馈", projects = "工作区记忆", workflows = "文件流程"
        var id: Self { self }
    }

    private enum Editor: Identifiable {
        case feedback(SearchFeedback), project(ProjectMemory), workflow(FileWorkflow)
        var id: UUID {
            switch self {
            case .feedback(let value): return value.id
            case .project(let value): return value.id
            case .workflow(let value): return value.id
            }
        }
    }

    var memory: AIMemory = .shared
    @ViewState private var page: Page = .feedback
    @ViewState private var editor: Editor?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("记忆保存在这台 Mac 上。").foregroundStyle(.secondary)
            Picker("记忆类别", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch page {
            case .feedback:
                records(memory.feedback, empty: "在搜索结果上右键，可以记住相关或不相关的文件。") { item in
                    row(item.context.query, detail: item.rating.rawValue + " · " + item.file.path,
                        edit: { editor = .feedback(item) }, delete: { memory.removeFeedback(item.id) })
                }
            case .projects:
                records(memory.projects, empty: "在「工作区」或「快速访问」中选择一个工作区，设置项目别名和目录。") { item in
                    row(item.name, detail: ([item.aliases.joined(separator: "、"), item.root?.path, item.delivery?.path]
                        .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · "),
                        edit: { editor = .project(item) }, delete: { memory.removeProject(item.id) })
                }
            case .workflows:
                records(memory.workflows, empty: "选中文件后，在右键「文件流程」中创建。") { item in
                    row(item.name, detail: item.details, edit: { editor = .workflow(item) },
                        delete: { memory.removeWorkflow(item.id) })
                }
                HStack {
                    Spacer()
                    Button("新建流程…") { editor = .workflow(FileWorkflow()) }
                }
            }
        }
        .padding(18)
        .frame(width: 635, height: 415)
        .sheet(item: $editor) { item in
            switch item {
            case .feedback(let item): SearchFeedbackEditor(memory: memory, feedback: item) { editor = nil }
            case .project(let item): ProjectMemoryEditor(memory: memory, project: item) { editor = nil }
            case .workflow(let item): FileWorkflowEditor(memory: memory, draft: item) { editor = nil }
            }
        }
    }

    @ViewBuilder private func records<Item: Identifiable, Content: View>(_ items: [Item], empty: String,
                                                                          @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("暂无记录", systemImage: "tray")
            } description: {
                Text(empty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items, rowContent: content)
                .listStyle(.inset)
        }
    }

    private func row(_ title: String, detail: String, edit: @escaping () -> Void,
                     delete: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        .help(detail)
                }
            }
            Spacer()
            Button("修改…", action: edit)
            Button("删除", role: .destructive, action: delete)
        }
        .buttonStyle(.borderless)
    }
}

struct SearchFeedbackEditor: View {
    let memory: AIMemory
    @ViewState var feedback: SearchFeedback
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("修改搜索反馈").font(.headline)
            Form {
                TextField("搜索词", text: $feedback.context.query)
                LabeledContent("结果文件", value: feedback.file.path)
                LabeledContent("搜索目录", value: feedback.context.root.path)
                if let name = feedback.context.workspaceName { LabeledContent("工作区", value: name) }
                Picker("排序", selection: $feedback.rating) {
                    ForEach(SearchFeedback.Rating.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") { if memory.save(feedback) { close() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(feedback.context.key.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
    }
}

struct ProjectMemoryEditor: View {
    let memory: AIMemory
    @ViewState var project: ProjectMemory
    let close: () -> Void
    @ViewState private var aliases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("工作区记忆").font(.headline)
            Form {
                LabeledContent("工作区", value: project.name)
                TextField("项目别名", text: $aliases, prompt: Text("用逗号分隔"))
                LocalFolderField(title: "搜索目录", url: $project.root)
                LocalFolderField(title: "交付目录", url: $project.delivery)
                Toggle("继续上次的面板布局", isOn: Binding(get: { project.resumesLayout != false }, set: { enabled in
                    project.resumesLayout = enabled
                    if !enabled { project.recentLayout = nil }
                }))
            }
            .formStyle(.grouped)
            Text("助手可以用项目别名查找文件，文件流程可以使用此工作区的交付目录。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") {
                    project.aliases = Array(aliases.split(whereSeparator: { ",，\n".contains($0) }).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }.prefix(16))
                    project.resumesLayout = project.resumesLayout ?? true
                    if project.root == nil, project.delivery == nil, project.aliases.isEmpty, project.resumesLayout == false {
                        memory.removeProject(project.id)
                        close()
                    } else if memory.save(project) { close() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 530)
        .onAppear { aliases = project.aliases.joined(separator: "，") }
    }
}

struct LocalFolderField: View {
    let title: String
    @Binding var url: URL?

    var body: some View {
        LabeledContent(title) {
            HStack {
                if let url {
                    Text(url.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
                }
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = url
                    if panel.runModal() == .OK { url = panel.url }
                }
                .accessibilityLabel("选择" + title)
                if url != nil {
                    Button("清除") { url = nil }.accessibilityLabel("清除" + title)
                }
            }
        }
    }
}
