import Foundation
import Observation
import Security

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI, deepSeek, compatible
    var id: Self { self }

    var title: String {
        switch self {
        case .openAI: return "OpenAI（ChatGPT）"
        case .deepSeek: return "DeepSeek"
        case .compatible: return "OpenAI 兼容服务"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .compatible: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .deepSeek: return "deepseek-flash"
        case .compatible: return ""
        }
    }
}

struct AIProfile: Codable, Equatable, Sendable {
    var model: String
    var baseURL: String

    func endpoint(for provider: AIProvider) -> URL? {
        let base = (provider == .compatible ? baseURL : provider.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let safeModel = model.nilIfBlank, safeModel.utf8.count <= 200,
              var parts = URLComponents(string: base),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        parts.scheme = scheme
        parts.host = host
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.percentEncodedPath = path
        return parts.url
    }
}

struct AIConnection: Sendable {
    let provider: AIProvider
    let endpoint: URL
    let model: String
    let apiKey: String?

    init(provider: AIProvider, profile: AIProfile, apiKey: String?) throws {
        guard let endpoint = profile.endpoint(for: provider), let model = profile.model.nilIfBlank else {
            throw AIServiceError.configuration
        }
        let key = apiKey?.nilIfBlank
        if provider != .compatible && key == nil { throw AIServiceError.missingKey }
        if let key, key.utf8.count > 8192 || key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw AIServiceError.invalidKey
        }
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.apiKey = key
    }
}

@MainActor @Observable
final class AISettingsStore {
    static let shared = AISettingsStore()

    private struct Credential: Hashable {
        let provider: AIProvider
        let endpoint: URL
    }

    private let defaults: UserDefaults
    private let keychain: AIKeychain
    @ObservationIgnored private var sessionKeys: [Credential: String] = [:]
    private var profiles: [AIProvider: AIProfile]
    private(set) var provider: AIProvider

    init(defaults: UserDefaults = .standard, keychain: AIKeychain = AIKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
        profiles = defaults.data(forKey: "wfolder.ai.profiles").flatMap {
            try? JSONDecoder().decode([AIProvider: AIProfile].self, from: $0)
        } ?? [:]
        provider = defaults.string(forKey: "wfolder.ai.provider").flatMap(AIProvider.init(rawValue:)) ?? .openAI
    }

    func profile(for provider: AIProvider) -> AIProfile {
        profiles[provider] ?? AIProfile(model: provider.defaultModel, baseURL: provider.baseURL)
    }

    func hasStoredKey(_ provider: AIProvider, profile: AIProfile) -> Bool {
        guard let endpoint = profile.endpoint(for: provider) else { return false }
        let credential = Credential(provider: provider, endpoint: endpoint)
        return sessionKeys[credential] != nil || keychain.contains(provider: provider, endpoint: endpoint)
    }

    func connection(provider: AIProvider, profile: AIProfile, newKey: String? = nil) throws -> AIConnection {
        guard let endpoint = profile.endpoint(for: provider) else { throw AIServiceError.configuration }
        if let newKey = newKey?.nilIfBlank {
            return try AIConnection(provider: provider, profile: profile, apiKey: newKey)
        }
        let credential = Credential(provider: provider, endpoint: endpoint)
        let key = try sessionKeys[credential] ?? keychain.read(provider: provider, endpoint: endpoint)
        let connection = try AIConnection(provider: provider, profile: profile, apiKey: key)
        sessionKeys[credential] = connection.apiKey
        return connection
    }

    func save(provider: AIProvider, profile: AIProfile, newKey: String) throws {
        let input = try connection(provider: provider, profile: profile, newKey: newKey)
        var next = profiles
        next[provider] = AIProfile(model: input.model, baseURL: profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let encoded = try JSONEncoder().encode(next)
        if newKey.nilIfBlank != nil, let key = input.apiKey {
            try keychain.save(key, provider: provider, endpoint: input.endpoint)
            sessionKeys[Credential(provider: provider, endpoint: input.endpoint)] = key
        }
        defaults.set(encoded, forKey: "wfolder.ai.profiles")
        defaults.set(provider.rawValue, forKey: "wfolder.ai.provider")
        profiles = next
        self.provider = provider
    }

    func deleteKey(provider: AIProvider, profile: AIProfile) throws {
        guard let endpoint = profile.endpoint(for: provider) else { throw AIServiceError.configuration }
        try keychain.delete(provider: provider, endpoint: endpoint)
        sessionKeys.removeValue(forKey: Credential(provider: provider, endpoint: endpoint))
    }
}

struct AIKeychain: Sendable {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "local.perchfiles.browser") + ".ai") {
        self.service = service
    }

    func contains(provider: AIProvider, endpoint: URL) -> Bool {
        var lookup = query(provider, endpoint)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var attributes: CFTypeRef?
        return SecItemCopyMatching(lookup as CFDictionary, &attributes) == errSecSuccess
    }

    func read(provider: AIProvider, endpoint: URL) throws -> String? {
        var lookup = query(provider, endpoint)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            throw AIServiceError.keychainPermission
        }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AIServiceError.keychain }
        return key
    }

    func save(_ key: String, provider: AIProvider, endpoint: URL) throws {
        let lookup = query(provider, endpoint)
        let data = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(lookup as CFDictionary, data as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              SecItemAdd(lookup.merging(data) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
            throw AIServiceError.keychain
        }
    }

    func delete(provider: AIProvider, endpoint: URL) throws {
        let status = SecItemDelete(query(provider, endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIServiceError.keychain }
    }

    private func query(_ provider: AIProvider, _ endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue + " · " + endpoint.absoluteString,
        ]
    }
}

enum AIServiceError: LocalizedError {
    case configuration, missingKey, invalidKey, keychain, keychainPermission, response, http(Int)

    var errorDescription: String? {
        switch self {
        case .configuration: return "请先填写模型名称和有效的 API 地址。自定义服务使用 HTTPS，本机服务也可使用 HTTP。"
        case .missingKey: return "请在 AI 设置里填写这个供应商的 API Key。"
        case .invalidKey: return "API Key 格式无效，请重新复制。"
        case .keychain: return "无法访问 macOS 钥匙串。请解锁钥匙串后重试。"
        case .keychainPermission: return "请允许 wfolder 从 macOS 钥匙串读取 API Key 后重试。"
        case .response: return "模型没有返回可解析的操作。请重试或换一个模型。"
        case .http(let code):
            switch code {
            case 301...399: return "服务返回了重定向。请填写实际的 API 地址。"
            case 401, 403: return "认证失败。请检查 API Key 和模型权限。"
            case 404: return "找不到 API 或模型。请检查地址和模型名称。"
            case 429: return "服务限流或余额不足。请检查供应商账户后重试。"
            default: return "AI 服务请求失败（HTTP \(code)）。"
            }
        }
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
