import SwiftUI

enum FileOperationsTab: String, CaseIterable, Identifiable {
    case transfers = "传输队列", history = "操作历史"
    var id: Self { self }
}

struct FileOperationsView: View {
    @Bindable var workspace: BrowserWorkspace
    @ViewState private var showsReview = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("文件操作", selection: $workspace.operationsTab) {
                    ForEach(FileOperationsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer(minLength: 8)
                Button("关闭", systemImage: "xmark") { workspace.showsOperations = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            switch workspace.operationsTab {
            case .transfers:
                if let job = workspace.transfers.conflictJob {
                    if showsReview {
                        ConflictReview(workspace: workspace, job: job) { showsReview = false }.id(job.reviewID)
                    } else {
                        Button("处理 \(job.conflicts.count) 个同名项目", systemImage: "exclamationmark.circle") {
                            showsReview = true
                        }
                        transferList
                    }
                } else {
                    transferList
                }
            case .history: historyList
            }
        }
        .padding(16)
        .frame(width: 630, height: 440)
        .onChange(of: workspace.transfers.conflictJob?.reviewID) { showsReview = true }
    }

    @ViewBuilder private var transferList: some View {
        if workspace.transfers.jobs.isEmpty {
            ContentUnavailableView("暂无传输任务", systemImage: "arrow.left.arrow.right")
        } else {
            List(workspace.transfers.jobs.reversed()) { job in
                TransferJobRow(workspace: workspace, job: job)
            }
            .listStyle(.inset)
            .accessibilityLabel("传输任务")
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.history.entries.isEmpty {
                ContentUnavailableView("暂无操作记录", systemImage: "clock.arrow.circlepath")
            } else {
                List(workspace.history.entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(entry.kind.rawValue) \(entry.count) 项").fontWeight(.semibold)
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                        if let detail = entry.detail {
                            Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(detail)
                        }
                        if let message = entry.undoMessage {
                            Text(message).foregroundStyle(.orange).textSelection(.enabled)
                        } else if entry.restoredCount > 0 {
                            Label(entry.remaining.isEmpty ? "已撤销" : "部分撤销", systemImage: "arrow.uturn.backward")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
                .accessibilityLabel("文件操作历史")
            }
            if let last = workspace.history.latestUndo {
                HStack {
                    Spacer()
                    Button("撤销\(last.kind.rawValue)", systemImage: "arrow.uturn.backward") {
                        workspace.undoFileOperation()
                    }
                    .disabled(!workspace.canUndoFileOperation)
                }
            }
        }
    }
}

private struct TransferJobRow: View {
    let workspace: BrowserWorkspace
    let job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(job.request.operation.title) \(job.total) 项").fontWeight(.semibold)
                Spacer()
                Text(job.cancelling && !job.state.finished ? "正在取消…" : job.state.rawValue)
                    .foregroundStyle(job.state == .partial ? Color.orange : Color.secondary)
                if !job.state.finished {
                    Button("取消") { workspace.transfers.cancel(job) }.disabled(job.cancelling)
                } else if !job.failures.isEmpty {
                    Button("重试失败项") { workspace.retryTransfer(job) }
                }
            }
            Text(job.sourceSummary + " → " + job.request.directory.path)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(job.sourceSummary + "\n" + job.request.directory.path)
            if !job.state.finished {
                ProgressView(value: Double(job.processed), total: Double(job.total))
                    .accessibilityLabel("传输项目进度")
            }
            if job.state == .running, let item = job.current {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack(spacing: 8) {
                        Text(item.name).lineLimit(1)
                        if item.stamp.regular, let meter = job.meter, meter.bytes > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: meter.bytes, countStyle: .file))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Text("已完成 \(job.completed.count)/\(job.total) · 跳过 \(job.skipped) · 失败 \(job.failures.count)")
                .foregroundStyle(.secondary).monospacedDigit()
            if !job.failures.isEmpty {
                Text(FileOperationResult(failures: job.failures).failureSummary)
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(job.warnings, id: \.self) { warning in
                Text(warning).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
    }
}

private struct ConflictReview: View {
    let workspace: BrowserWorkspace
    let job: TransferJob
    let showTasks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(job.conflicts.count) 个同名项目").font(.headline)
            Text(job.request.directory.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            List(job.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(conflict.item.name).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        Picker("处理方式", selection: Binding(
                            get: { job.draftDecisions[conflict.id] ?? .skip },
                            set: { job.draftDecisions[conflict.id] = $0 }
                        )) {
                            ForEach(ConflictDecision.allCases.filter { $0 != .replace || conflict.canReplace }) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 116)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        description("源项目", url: conflict.item.url, stamp: conflict.item.stamp)
                        description("同名项目", url: conflict.occupant, stamp: conflict.stamp)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
            .accessibilityLabel("同名文件对比")
            if job.draftDecisions.values.contains(.replace) {
                Text("被替换的旧文件会移入废纸篓。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Menu("全部设为") {
                    ForEach(ConflictDecision.allCases.filter { $0 != .replace || job.conflicts.contains(where: \.canReplace) }) { decision in
                        Button(decision == .replace ? "替换可替换文件，其余保留两份" : decision.rawValue) {
                            job.draftDecisions = Dictionary(uniqueKeysWithValues: job.conflicts.map {
                                ($0.id, decision == .replace && !$0.canReplace ? .keepBoth : decision)
                            })
                        }
                    }
                }
                Button("查看任务", action: showTasks)
                Spacer()
                Button("取消任务") { workspace.transfers.cancel(job) }.disabled(job.cancelling)
                Button("继续传输") { workspace.transfers.resolve(job, decisions: job.draftDecisions) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.cancelling)
            }
        }
    }

    private func description(_ heading: String, url: URL, stamp: FileStamp) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading).fontWeight(.medium)
            Text(url.deletingLastPathComponent().path).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                if stamp.directory { Text("文件夹") }
                else { Text(ByteCountFormatter.string(fromByteCount: stamp.bytes, countStyle: .file)) }
                Text(stamp.modified, format: .dateTime.year().month().day().hour().minute()).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(url.path)
    }
}
