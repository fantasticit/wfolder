import Foundation

enum FileViewMode: String, Codable, CaseIterable, Identifiable {
    case details = "详情列表"
    case medium = "中等缩略图"
    case large = "大缩略图"

    var id: Self { self }
}

enum FileGrouping: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "不分组"
    case kind = "类型"
    case modified = "修改日期"

    var id: Self { self }
}

struct FileViewSettings: Codable, Equatable {
    var compactRows = false
    var showExtensions = true
    var hiddenColumns: Set<FileColumn> = []
    var columnWidths: [FileColumn: Double] = [:]

    static let defaultsKey = "wfolder.fileViewSettings"

    static func restore() -> Self {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func store() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct GroupedFileRows: Sendable {
    enum Row: Sendable { case heading(String), item(Int) }

    let id = UUID()
    let listingID: UUID
    let rows: [Row]
    let rowsByFile: [URL: Int]

    init(listing: FileListing, grouping: FileGrouping, now: Date = .now, calendar: Calendar = .current) throws {
        listingID = listing.id
        var groups: [(String, [Int])] = []
        if grouping == .kind {
            var types: [String: [Int]] = [:]
            for (index, entry) in listing.entries.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                types[entry.kind, default: []].append(index)
            }
            let typesInOrder = types.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            groups = typesInOrder.map { ($0, types[$0] ?? []) }
        } else if grouping == .modified {
            let today = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let priorWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
            let month = calendar.dateInterval(of: .month, for: now)?.start ?? today
            let labels = ["未来日期", "今天", "昨天", "本周", "上周", "本月", "更早", "未知日期"]
            var dates = Array(repeating: [Int](), count: labels.count)
            for (index, entry) in listing.entries.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                let bucket: Int
                switch entry.modified {
                case let date? where date >= tomorrow: bucket = 0
                case let date? where date >= today: bucket = 1
                case let date? where date >= yesterday: bucket = 2
                case let date? where date >= week: bucket = 3
                case let date? where date >= priorWeek: bucket = 4
                case let date? where date >= month: bucket = 5
                case .some: bucket = 6
                case nil: bucket = 7
                }
                dates[bucket].append(index)
            }
            groups = Array(zip(labels, dates).filter { !$0.1.isEmpty })
        }
        var rows: [Row] = []
        var fileRows: [URL: Int] = [:]
        rows.reserveCapacity(listing.entries.count + groups.count)
        fileRows.reserveCapacity(listing.entries.count)
        for (label, indexes) in groups {
            rows.append(.heading(label))
            for index in indexes {
                if index % 256 == 0 { try Task.checkCancellation() }
                fileRows[listing.entries[index].id] = rows.count
                rows.append(.item(index))
            }
        }
        self.rows = rows
        rowsByFile = fileRows
    }
}
