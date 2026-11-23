import Foundation

enum PaneSplitDirection: String, Codable {
    case sideBySide, stacked
}

indirect enum PaneLayout: Identifiable {
    static let dividerWidth: CGFloat = 5

    case pane(BrowserModel)
    case split(UUID, PaneSplitDirection, PaneLayout, PaneLayout)

    var id: UUID {
        switch self {
        case .pane(let browser): return browser.id
        case .split(let id, _, _, _): return id
        }
    }

    var browsers: [BrowserModel] {
        switch self {
        case .pane(let browser): return [browser]
        case .split(_, _, let first, let second): return first.browsers + second.browsers
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .pane: return CGSize(width: 210, height: 166)
        case .split(_, let direction, let first, let second):
            let a = first.minimumSize
            let b = second.minimumSize
            switch direction {
            case .sideBySide:
                return CGSize(width: a.width + b.width + Self.dividerWidth, height: max(a.height, b.height))
            case .stacked:
                return CGSize(width: max(a.width, b.width), height: a.height + b.height + Self.dividerWidth)
            }
        }
    }

    var splitIDs: Set<UUID> {
        switch self {
        case .pane: return []
        case .split(let id, _, let first, let second): return first.splitIDs.union(second.splitIDs).union([id])
        }
    }

    @MainActor func snapshot(proportions: [UUID: CGFloat]) -> LayoutSnapshot {
        switch self {
        case .pane(let browser): return .pane(browser.snapshot)
        case .split(let id, let direction, let first, let second):
            return .split(direction, proportions[id] ?? 0.5,
                          first.snapshot(proportions: proportions), second.snapshot(proportions: proportions))
        }
    }

    @MainActor static func restore(_ snapshot: LayoutSnapshot, session: BrowserSession,
                                   proportions: inout [UUID: CGFloat]) -> Self {
        switch snapshot {
        case .pane(let pane): return .pane(BrowserModel(snapshot: pane, session: session))
        case .split(let direction, let ratio, let first, let second):
            let id = UUID()
            proportions[id] = ratio.isFinite ? min(1, max(0, ratio)) : 0.5
            return .split(id, direction, restore(first, session: session, proportions: &proportions),
                          restore(second, session: session, proportions: &proportions))
        }
    }

    func inserting(_ browser: BrowserModel, beside id: UUID, direction: PaneSplitDirection) -> Self {
        switch self {
        case .pane(let current):
            return current.id == id ? .split(UUID(), direction, self, .pane(browser)) : self
        case .split(let branchID, let axis, let first, let second):
            return .split(branchID, axis, first.inserting(browser, beside: id, direction: direction),
                          second.inserting(browser, beside: id, direction: direction))
        }
    }

    func removing(_ browserID: UUID) -> Self? {
        switch self {
        case .pane(let browser): return browser.id == browserID ? nil : self
        case .split(let branchID, let axis, let first, let second):
            guard let a = first.removing(browserID) else { return second }
            guard let b = second.removing(browserID) else { return first }
            return .split(branchID, axis, a, b)
        }
    }
}
