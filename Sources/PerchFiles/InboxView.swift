import SwiftUI
import UniformTypeIdentifiers

struct InboxView: View {
    let workspace: BrowserWorkspace
    @ViewState private var importing: FileWorkflow?
    @ViewState private var issue: String?
    @ViewState private var archiving: Set<URL> = []

    private var inbox: ProjectInbox { workspace.professional.inbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let folder = inbox.folder {
                HStack {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .help(folder.path)
                    Spacer()
                    Button("更换收件文件夹…", action: chooseInbox)
                    Menu("收件设置") {
                        Button("检查新文件") { Task { await inbox.refresh() } }
                        Button("停止监看") { inbox.watch(nil) }
                    }
                }
            }
            if let message = issue ?? inbox.issue {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if inbox.folder == nil {
                ContentUnavailableView {
                    Label("从哪里收文件？", systemImage: "tray")
                } description: {
                    Text("wfolder 会在打开期间查看此文件夹。选好目标后才会移动文件。")
                } actions: {
                    Button("使用下载文件夹") { inbox.watch(URL.downloadsDirectory) }.buttonStyle(.borderedProminent)
                    Button("选择其他文件夹…", action: chooseInbox)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if inbox.items.isEmpty {
                ContentUnavailableView("暂无待归档文件", systemImage: "tray",
                    description: Text("下载完成或复制完毕的文件会显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(inbox.items) { item in
                    let projects = workspace.aiMemory.projects
                    let suggestion = inbox.suggestion(for: item, projects: projects)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.url.lastPathComponent).lineLimit(1).help(item.url.path)
                            if let suggestion, let project = projects.first(where: { $0.id == suggestion.0 }) {
                                Text("建议归档到 \(project.name) · \(suggestion.1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if archiving.contains(item.url) { ProgressView().controlSize(.small) }
                        Menu("归档到…") {
                            ForEach(projects) { project in
                                Button(project.name) { archive(item, project: project) }
                                    .disabled(project.delivery == nil && workspace.searchRoot(for: project) == nil)
                            }
                            if !projects.isEmpty { Divider() }
                            Button("其他文件夹…") { chooseTarget(for: item) }
                        }
                        .disabled(archiving.contains(item.url))
                        Button("忽略") { inbox.dismiss(item) }.disabled(archiving.contains(item.url))
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text("文件流程").fontWeight(.medium)
                Spacer()
                Button("导入流程…", action: importWorkflow)
                Menu("导出流程…") {
                    ForEach(workspace.aiMemory.workflows) { workflow in
                        Button(workflow.name) { exportWorkflow(workflow) }
                    }
                }.disabled(workspace.aiMemory.workflows.isEmpty)
            }
        }
        .sheet(item: $importing) { workflow in
            FileWorkflowEditor(memory: workspace.aiMemory, draft: workflow) { importing = nil }
        }
    }

    private func chooseFolder(startAt directory: URL?, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseInbox() {
        if let folder = chooseFolder(startAt: inbox.folder ?? .downloadsDirectory, prompt: "使用此文件夹") {
            inbox.watch(folder)
        }
    }

    private func chooseTarget(for item: ProjectInbox.Item) {
        if let target = chooseFolder(startAt: workspace.directoryBrowser?.directory, prompt: "移动到这里") {
            archive(item, at: target)
        }
    }

    private func archive(_ item: ProjectInbox.Item, project: ProjectMemory) {
        guard let target = project.delivery ?? workspace.searchRoot(for: project) else { return }
        archive(item, at: target, project: project.id)
    }

    private func archive(_ item: ProjectInbox.Item, at target: URL, project: UUID? = nil) {
        guard target.standardizedFileURL != item.url.deletingLastPathComponent().standardizedFileURL else {
            issue = "请选择收件目录以外的归档目标。"
            return
        }
        issue = nil
        archiving.insert(item.url)
        if !workspace.transfer([item.url], into: target, operation: .move, expectedSources: [item.url: item.stamp],
                               onFinish: { job in
                                   archiving.remove(item.url)
                                   if !job.moved.isEmpty {
                                       if let project { inbox.remember(item, project: project) }
                                       else { Task { await inbox.refresh() } }
                                   } else { issue = "文件未归档。详情可在传输队列查看。" }
                               }) {
            archiving.remove(item.url)
            issue = "无法开始归档。"
        }
    }

    private func importWorkflow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importing = try WorkflowTemplate.read(url); issue = nil }
        catch { issue = "无法导入流程。\(error.localizedDescription)" }
    }

    private func exportWorkflow(_ workflow: FileWorkflow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = workflow.name.replacingOccurrences(of: "/", with: "-") + ".wfolder-workflow.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(WorkflowTemplate(workflow)).write(to: url, options: .atomic)
            issue = nil
        } catch { issue = error.localizedDescription }
    }
}
