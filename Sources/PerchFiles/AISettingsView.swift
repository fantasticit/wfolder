import SwiftUI

struct AISettingsView: View {
    private let settings = AISettingsStore.shared
    private let onClose: (() -> Void)?
    @ViewState private var provider: AIProvider
    @ViewState private var profile: AIProfile
    @ViewState private var key = ""
    @ViewState private var keyStored = false
    @ViewState private var test: Task<Void, Never>?
    @ViewState private var feedback: String?
    @ViewState private var failed = false

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        let provider = AISettingsStore.shared.provider
        _provider = State(initialValue: provider)
        _profile = State(initialValue: AISettingsStore.shared.profile(for: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("AI 服务", systemImage: "sparkles").font(.headline)
                Spacer()
                if let onClose {
                    Button("返回助手", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .disabled(test != nil)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("供应商")
                    Picker("供应商", selection: $provider) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("模型")
                    TextField("模型名称", text: $profile.model).labelsHidden()
                }
                GridRow {
                    Text("API 地址")
                    if provider == .compatible {
                        TextField("https://服务地址/v1", text: $profile.baseURL).labelsHidden()
                    } else {
                        Text(provider.baseURL).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                GridRow {
                    Text("API Key")
                    SecureField(keyStored ? "已保存在钥匙串，留空沿用" : "粘贴供应商的 API Key", text: $key)
                }
            }
            .disabled(test != nil)

            Text(provider == .compatible
                 ? "兼容 Chat Completions 接口。本机服务可使用 HTTP，并可按服务要求留空 API Key。"
                 : "API Key 由供应商的 API 控制台签发，并保存到 macOS 钥匙串。")
                .font(.caption).foregroundStyle(.secondary)

            if let feedback {
                Label(feedback, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .font(.callout)
            } else if test != nil {
                ProgressView("正在测试连接…").controlSize(.small)
            }
            Spacer(minLength: 0)
            HStack {
                if keyStored {
                    Button("移除已保存的 Key", role: .destructive, action: removeKey).disabled(test != nil)
                }
                Spacer()
                if let test {
                    Button("停止测试") { test.cancel(); self.test = nil }
                } else {
                    Button("测试连接", action: testConnection).disabled(!canConnect)
                    Button("保存并启用", action: save).disabled(!canConnect).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 570, height: 328)
        .onAppear(perform: refreshKey)
        .onChange(of: provider) {
            profile = settings.profile(for: provider)
            key = ""
            refreshKey()
            feedback = nil
        }
        .onChange(of: profile.baseURL) { refreshKey(); feedback = nil }
        .onChange(of: profile.model) { refreshKey(); feedback = nil }
        .onDisappear { test?.cancel(); test = nil }
    }

    private var canConnect: Bool {
        profile.endpoint(for: provider) != nil &&
            (provider == .compatible || keyStored || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func refreshKey() {
        keyStored = settings.hasStoredKey(provider, profile: profile)
    }

    private func save() {
        do {
            try settings.save(provider: provider, profile: profile, newKey: key)
            key = ""
            refreshKey()
            failed = false
            feedback = "已保存并启用 " + provider.title
        } catch { show(error) }
    }

    private func removeKey() {
        do {
            try settings.deleteKey(provider: provider, profile: profile)
            key = ""
            refreshKey()
            failed = false
            feedback = "已移除保存的 API Key"
        } catch { show(error) }
    }

    private func testConnection() {
        feedback = nil
        test = Task {
            do {
                let connection = try settings.connection(provider: provider, profile: profile, newKey: key)
                let result = try await AIClient.shared.propose("左右分屏", using: connection)
                try Task.checkCancellation()
                guard result.action == .split, result.direction == "leftRight" else { throw AIServiceError.response }
                failed = false
                feedback = "连接成功，模型可解析文件操作"
            } catch {
                if !Task.isCancelled { show(error) }
            }
            if !Task.isCancelled { test = nil }
        }
    }

    private func show(_ error: Error) {
        failed = true
        feedback = error.localizedDescription
    }
}
