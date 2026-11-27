import Foundation
import Observation

struct DeliveryTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var required: String
    var namePattern = ""

    static let presets = [
        Self(id: "assets", title: "素材交付", required: "png|jpg|jpeg|webp|mp4|mov|wav|pdf"),
        Self(id: "release", title: "软件发布", required: "zip|dmg|pkg|tar|gz, sha256|sha256sum"),
        Self(id: "custom", title: "自定义", required: "")
    ]
}

struct DeliveryPlan: Sendable {
    struct Row: Identifiable, Sendable {
        let url: URL
        let path: String
        let stamp: FileStamp
        var id: URL { url }
    }

    let rows: [Row]
    let unavailable: [String]

    init(items: [URL]) throws {
        var built: [Row] = []
        var skipped: [String] = []
        let fm = FileManager.default
        for url in FileSystem.selectedRoots(items) {
            try Task.checkCancellation()
            guard let stamp = FileStamp(url) else { skipped.append(url.lastPathComponent); continue }
            if stamp.regular {
                built.append(Row(url: url, path: url.lastPathComponent, stamp: stamp))
            } else if stamp.directory, url.path != "/" {
                let folder = FileSystem.physicalDirectory(url)
                guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { inaccessible, _ in
                        skipped.append(inaccessible.lastPathComponent)
                        return !Task.isCancelled
                    }) else { skipped.append(url.lastPathComponent); continue }
                let prefix = folder.path + "/"
                for case let member as URL in entries {
                    try Task.checkCancellation()
                    guard member.path.hasPrefix(prefix), let metadata = FileStamp(member) else {
                        skipped.append(member.lastPathComponent)
                        continue
                    }
                    if metadata.regular {
                        built.append(Row(url: member, path: url.lastPathComponent + "/" + member.path.dropFirst(prefix.count),
                                         stamp: metadata))
                    } else if !metadata.directory { skipped.append(member.lastPathComponent) }
                }
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        rows = built.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        unavailable = skipped
    }

    static func issues(in rows: [Row], template: DeliveryTemplate) -> [String] {
        guard !rows.isEmpty else { return ["请选择需要交付的文件。"] }
        var names: Set<String> = []
        var collisions: [String] = []
        var prefixes: Set<String> = []
        for row in rows {
            let key = row.path.precomposedStringWithCanonicalMapping.lowercased()
            if !names.insert(key).inserted || key == ".wfolder-manifest.json" { collisions.append(row.path) }
            var parent = (key as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                prefixes.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        collisions += names.intersection(prefixes).sorted()
        let extensions = Set(rows.map { $0.url.pathExtension.lowercased() })
        let missing = template.required.split(whereSeparator: { ",，".contains($0) }).compactMap { group -> String? in
            let choices = group.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return !choices.isEmpty && choices.allSatisfy { !extensions.contains($0) } ? choices.joined(separator: " / ") : nil
        }
        var result = collisions.prefix(8).map { "交付路径冲突 · " + $0 }
        result += missing.map { "缺少格式 · " + $0 }
        if !template.namePattern.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: template.namePattern) else {
                return result + ["文件名表达式无效。"]
            }
            for row in rows {
                let name = row.url.lastPathComponent
                if regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil {
                    result.append("文件名不符合要求 · " + name)
                    if result.count >= 20 { break }
                }
            }
        }
        return result
    }
}

struct DeliveryRecord: Codable, Identifiable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    let id: UUID
    let date: Date
    let project: String
    let template: String
    let target: URL
    let archive: URL?
    let sha256: String?
    let entries: [Entry]
    let skipped: [String]
    let error: String?
    var baseline: URL? = nil

    func differences(from prior: Self) -> [String] {
        let previous = Dictionary(prior.entries.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(entries.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        return Set(previous.keys).union(current.keys).sorted().compactMap { path in
            if previous[path] == nil { return "+ " + path }
            if current[path] == nil { return "− " + path }
            return previous[path] != current[path] ? "更改 · " + path : nil
        }
    }
}

enum DeliveryPackage {
    struct Manifest: Codable {
        let created: Date
        let project: String
        let files: [DeliveryRecord.Entry]
    }

    static func build(rows: [DeliveryPlan.Row], template: DeliveryTemplate, project: String,
                      name: String, destination: URL, skipped: [String]) throws -> DeliveryRecord {
        guard DeliveryPlan.issues(in: rows, template: template).isEmpty else { throw DeliveryError.checks }
        let clean = try FileSystem.validateName(name)
        let target = try TransferFiles.Destination(destination)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("wfolder-delivery-" + UUID().uuidString, isDirectory: true)
        let contents = staging.appendingPathComponent("contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let date = Date.now
        let entries = try rows.map { row in
            try Task.checkCancellation()
            let output = contents.appendingPathComponent(row.path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let digest = try VerifiedFile.sha256(row.url, stamp: row.stamp, copyingTo: output)
            return DeliveryRecord.Entry(path: row.path, bytes: row.stamp.bytes, sha256: digest)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(Manifest(created: date, project: project, files: entries))
        try manifest.write(to: contents.appendingPathComponent(".wfolder-manifest.json"), options: .atomic)
        let inputs = try fm.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil)
        let archive = try FileArchive.compress(inputs, in: contents)
        guard let stamp = FileStamp(archive) else { throw DeliveryError.verification }
        let digest = try VerifiedFile.sha256(archive, stamp: stamp)
        try Task.checkCancellation()
        try target.validate()
        let output = try FileArchive.publish(archive, in: target.physical, name: clean, extension: ".zip")
        guard let written = FileStamp(output), try VerifiedFile.sha256(output, stamp: written) == digest else {
            throw DeliveryError.verification
        }
        let checksum = output.appendingPathExtension("sha256")
        let checksumInput = staging.appendingPathComponent("archive.sha256")
        try Data("\(digest)  \(output.lastPathComponent)\n".utf8).write(to: checksumInput, options: .withoutOverwriting)
        do { try TransferFiles.publish(checksumInput, to: checksum) }
        catch { throw DeliveryError.checksumFile(output.path, error.localizedDescription) }
        return DeliveryRecord(id: UUID(), date: date, project: project, template: template.title, target: target.url,
                              archive: output, sha256: digest, entries: entries, skipped: skipped, error: nil)
    }

    enum DeliveryError: LocalizedError {
        case checks, verification, checksumFile(String, String)
        var errorDescription: String? {
            switch self {
            case .checks: return "请先处理交付清单中的检查项。"
            case .verification: return "ZIP 校验失败。请检查目标目录中的文件。"
            case .checksumFile(let path, let issue): return "ZIP 已写入 \(path)，但保存校验文件失败。\(issue)"
            }
        }
    }
}

@MainActor @Observable
final class DeliveryHistory {
    private let storage: ProfessionalStorage
    private(set) var records: [DeliveryRecord]
    private(set) var issue: String?
    private(set) var templates: [DeliveryTemplate] = []
    var isBuilding = false

    init(storage: ProfessionalStorage) {
        self.storage = storage
        do { records = try storage.load([DeliveryRecord].self, "deliveries.json") ?? [] }
        catch { records = []; issue = "无法读取交付记录。" }
        do { templates = try storage.load([DeliveryTemplate].self, "delivery-templates.json") ?? [] }
        catch { issue = "无法读取交付模板。" }
    }

    func saveTemplate(_ template: DeliveryTemplate) -> Bool {
        guard !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let values = templates.filter { $0.id != template.id } + [template]
        do { try storage.save(values, "delivery-templates.json"); issue = nil }
        catch { issue = error.localizedDescription; return false }
        templates = values
        return true
    }

    func append(_ record: DeliveryRecord) {
        let values = [record] + records.prefix(199)
        let retired = records.dropFirst(199).filter { $0.baseline != nil }.map(\.id)
        do {
            try storage.save(values, "deliveries.json")
            for id in retired {
                let folder = storage.directory.appendingPathComponent("baselines/" + id.uuidString, isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
            }
            issue = nil
        }
        catch { issue = "交付记录未写入磁盘。\(error.localizedDescription)" }
        records = values
    }

    func previous(for record: DeliveryRecord) -> DeliveryRecord? {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return nil }
        return records.dropFirst(index + 1).first { $0.project == record.project && $0.template == record.template &&
            $0.target.standardizedFileURL.path == record.target.standardizedFileURL.path && $0.error == nil }
    }
}
