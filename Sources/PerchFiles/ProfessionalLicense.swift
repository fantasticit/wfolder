import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfessionalLicense: Decodable {
    struct Claims: Decodable {
        let id: UUID
        let product: String
        let edition: String
        let licensee: String
    }

    let payload: Data
    let signature: Data

    static func verify(_ data: Data, publicKey: Data) throws -> Claims {
        guard data.count <= 16 * 1024 else { throw LicenseError.invalid }
        let license = try JSONDecoder().decode(Self.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(license.signature, for: license.payload) else { throw LicenseError.invalid }
        let claims = try JSONDecoder().decode(Claims.self, from: license.payload)
        guard claims.product == "wfolder", claims.edition == "pro",
              !claims.licensee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              claims.licensee.count <= 160 else { throw LicenseError.invalid }
        return claims
    }

    enum LicenseError: LocalizedError {
        case invalid
        var errorDescription: String? { "许可证无效或不适用于 wfolder Pro。" }
    }
}

@MainActor @Observable
final class ProfessionalEntitlement {
    enum Status: Equatable {
        case development, trial(Int), licensed(String), expired, misconfigured

        var allowsTools: Bool {
            switch self {
            case .development, .trial, .licensed: true
            case .expired, .misconfigured: false
            }
        }

        var label: String {
            switch self {
            case .development: ""
            case .trial(let days): "Pro 试用 · 剩余 \(days) 天"
            case .licensed(let name): "Pro · \(name)"
            case .expired: "Pro 试用已结束"
            case .misconfigured: "Pro 发布配置无效"
            }
        }
    }

    private struct Trial: Codable {
        let started: Date
        var lastSeen: Date
    }

    private let key: Data?
    private let configured: Bool
    private let storage: ProfessionalStorage
    let checkout: URL?
    private(set) var status: Status

    init(storage: ProfessionalStorage, bundle: Bundle = .main) {
        let rawKey = bundle.object(forInfoDictionaryKey: "WFolderProPublicKey") as? String
        configured = rawKey != nil
        key = rawKey.flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        self.storage = storage
        if let raw = bundle.object(forInfoDictionaryKey: "WFolderProCheckoutURL") as? String,
           let url = URL(string: raw), url.scheme == "https", url.host != nil {
            checkout = url
        } else { checkout = nil }
        status = configured ? .expired : .development
    }

    func refresh() {
        guard configured else { return }
        guard let key else { status = .misconfigured; return }
        if let data = try? storage.load(Data.self, "pro-license.json"),
           let claims = try? ProfessionalLicense.verify(data, publicKey: key) {
            status = .licensed(claims.licensee)
            return
        }
        do {
            let now = Date()
            var trial = try storage.load(Trial.self, "pro-trial.json") ?? Trial(started: now, lastSeen: now)
            trial.lastSeen = max(trial.lastSeen, now)
            try storage.save(trial, "pro-trial.json")
            let seconds = 14 * 86_400.0 - trial.lastSeen.timeIntervalSince(trial.started)
            status = seconds > 0 ? .trial(Int(ceil(seconds / 86_400))) : .expired
        } catch { status = .expired }
    }

    func activate(_ url: URL) throws {
        guard let key, let stamp = FileStamp(url), stamp.regular, stamp.bytes <= 16 * 1024 else {
            throw ProfessionalLicense.LicenseError.invalid
        }
        let input = try VerifiedFile.open(url, stamp: stamp)
        defer { try? input.close() }
        let data = try input.read(upToCount: 16 * 1024 + 1) ?? Data()
        let claims = try ProfessionalLicense.verify(data, publicKey: key)
        try storage.save(data, "pro-license.json")
        status = .licensed(claims.licensee)
    }
}

struct ProfessionalLicenseView: View {
    let entitlement: ProfessionalEntitlement
    @ViewState private var issue: String?

    private var offersPurchase: Bool {
        switch entitlement.status {
        case .trial, .expired: true
        case .licensed, .development, .misconfigured: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entitlement.status.label).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if let checkout = entitlement.checkout, offersPurchase {
                    Link("购买 Pro", destination: checkout)
                }
                Button("导入许可证…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try entitlement.activate(url); issue = nil }
                    catch { issue = error.localizedDescription }
                }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}
