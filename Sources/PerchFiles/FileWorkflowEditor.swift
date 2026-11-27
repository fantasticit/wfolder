import SwiftUI

struct FileWorkflowEditor: View {
    let memory: AIMemory
    @ViewState var draft: FileWorkflow
    var selectionCount = 0
    var run: ((FileWorkflow) -> Void)? = nil
    let close: () -> Void
    @ViewState private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("文件流程").font(.headline)
            Form {
                TextField("名称", text: $draft.name)
                if selectionCount > 0 { LabeledContent("当前选择", value: "\(selectionCount) 项") }
                Toggle("批量重命名", isOn: Binding(get: { draft.rename != nil }, set: { enabled in
                    draft.rename = enabled ? BatchRenameRule(style: .modifiedDate) : nil
                }))
                if let rename = draft.rename {
                    renameFields(rename)
                }
                Toggle("压缩为 ZIP", isOn: $draft.compresses)
                Picker("传输", selection: $draft.transfer) {
                    ForEach(FileWorkflow.Transfer.allCases) { Text($0.rawValue).tag($0) }
                }
                if draft.transfer != .none {
                    Toggle("使用当前工作区的交付目录", isOn: $draft.usesProjectDelivery)
                    if !draft.usesProjectDelivery {
                        LocalFolderField(title: "目标目录", url: $draft.destination)
                    }
                }
            }
            .formStyle(.grouped)
            if draft.hasActions {
                Text(draft.details).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if draft.compresses && draft.transfer != .none {
                Text("传输步骤处理生成的 ZIP。").font(.caption).foregroundStyle(.secondary)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                if let run {
                    Button("运行一次") { run(normalized) }
                        .disabled(!normalized.isValid)
                }
                Button("保存流程") {
                    if memory.save(normalized) { close() }
                    else { issue = "已有同名流程，请换一个名称。" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!normalized.isValid)
            }
        }
        .padding(18)
        .frame(width: 575)
        .onChange(of: draft.name) { issue = nil }
    }

    private var normalized: FileWorkflow {
        var result = draft
        result.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    @ViewBuilder private func renameFields(_ rename: BatchRenameRule) -> some View {
        Picker("重命名规则", selection: field(\.style, rename)) {
            ForEach(BatchRenameRule.Style.allCases) { Text($0.rawValue).tag($0) }
        }
        if rename.style != .modifiedDate {
            TextField(rename.style == .replace ? "查找文字" : "前缀", text: field(\.text, rename))
        }
        if rename.style == .replace {
            TextField("替换为", text: field(\.replacement, rename))
        }
        if rename.style == .sequence {
            TextField("起始编号", text: field(\.start, rename))
        }
    }

    private func field<Value>(_ key: WritableKeyPath<BatchRenameRule, Value>, _ fallback: BatchRenameRule) -> Binding<Value> {
        Binding(get: { (draft.rename ?? fallback)[keyPath: key] },
                set: { draft.rename?[keyPath: key] = $0 })
    }
}
