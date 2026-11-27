import SwiftUI

struct ResumableTransfersView: View {
    let workspace: BrowserWorkspace
    @ViewState var files: [URL]
    @ViewState private var destination: URL?
    @ViewState private var queueing = false

    private var transfers: ResumableTransfers { workspace.professional.transfers }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(files.isEmpty ? "选择要复制的文件" : "\(files.count) 个文件待复制")
                        .fontWeight(.medium)
                    if !files.isEmpty {
                        Text(files.prefix(3).map(\.lastPathComponent).joined(separator: "、") + (files.count > 3 ? " 等" : ""))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(files.isEmpty ? "选择文件…" : "更换文件…", action: chooseFiles)
                    .buttonStyle(.bordered)
                    .disabled(queueing)
            }
            if !files.isEmpty {
                LocalFolderField(title: "复制到", url: $destination).disabled(queueing)
                HStack {
                    if queueing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(destination == nil ? "选择位置并复制…" : "开始复制", action: startCopy)
                        .buttonStyle(.borderedProminent)
                        .disabled(queueing)
                }
            }
            if let issue = transfers.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if transfers.jobs.isEmpty {
                ContentUnavailableView {
                    Label("暂无复制任务", systemImage: "doc.on.doc")
                } description: {
                    Text("复制时可暂停。重新连接磁盘或重启 wfolder 后，在这里继续。")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queue
            }
        }
        .onAppear { if destination == nil { destination = workspace.activeProjectMemory?.delivery } }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("复制任务").font(.headline)
                Spacer()
                if transfers.jobs.contains(where: { $0.status == .waiting }), transfers.active == nil {
                    Button("开始等待中的任务") { transfers.startWaiting() }
                }
            }
            List(Array(transfers.jobs.reversed())) { job in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(job.targetName).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        Text(job.status.rawValue).foregroundStyle(.secondary)
                        actions(job)
                    }
                    Text(job.destination.path).lineLimit(1).truncationMode(.middle).help(job.destination.path)
                        .font(.caption).foregroundStyle(.secondary)
                    if transfers.active == job.id {
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            ProgressView(value: Double(transfers.meter.bytes), total: Double(max(1, job.original.bytes)))
                                .accessibilityLabel("复制进度")
                        }
                    }
                    if let error = job.message { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    if job.status == .completed, let hash = job.digest {
                        Text("SHA-256 " + hash).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.directoryURL = workspace.directoryBrowser?.directory
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { files = panel.urls }
    }

    private func startCopy() {
        guard !files.isEmpty, !queueing else { return }
        if destination == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "复制到这里"
            guard panel.runModal() == .OK else { return }
            destination = panel.url
        }
        guard let destination else { return }
        queueing = true
        Task {
            if await transfers.enqueue(files, to: destination) { files = [] }
            queueing = false
        }
    }

    @ViewBuilder private func actions(_ job: ResumableTransfer) -> some View {
        if transfers.active == job.id {
            Button("暂停") { transfers.pause() }
        } else if job.status == .paused {
            Button("继续复制") { transfers.resume(job.id) }
            Button("移除任务", role: .destructive) { Task { await transfers.remove(job) } }
        } else if job.status == .completed {
            Button("定位文件") {
                workspace.presentedTool = nil
                workspace.revealInFolder(job.target)
            }
            Button("移除记录") { Task { await transfers.remove(job) } }
        }
    }
}
