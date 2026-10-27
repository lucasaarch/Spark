import Foundation

enum SplitAxis: String, Codable { case horizontal, vertical }

/// A tab owns a tree of panes. Leaf IDs are session IDs; split IDs survive edits.
indirect enum PaneLayout: Codable, Equatable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    var sessionIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second): first.sessionIDs + second.sessionIDs
        }
    }

    var splitIDs: [UUID] {
        switch self {
        case .pane: []
        case .split(let id, _, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    func splitting(_ target: UUID, with newID: UUID, axis: SplitAxis) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == target ? .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .pane(newID)) : self
        case .split(let id, let direction, let ratio, let first, let second):
            return .split(id: id, axis: direction, ratio: ratio,
                          first: first.splitting(target, with: newID, axis: axis),
                          second: second.splitting(target, with: newID, axis: axis))
        }
    }

    func removing(_ target: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            let left = first.removing(target), right = second.removing(target)
            if let left, let right { return .split(id: id, axis: axis, ratio: ratio, first: left, second: right) }
            return left ?? right
        }
    }

    func settingRatio(_ value: Double, for target: UUID) -> PaneLayout {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: id == target ? min(0.9, max(0.1, value)) : ratio,
                          first: first.settingRatio(value, for: target), second: second.settingRatio(value, for: target))
        }
    }

    func isValid(depth: Int = 0) -> Bool {
        guard depth <= 8 else { return false }
        switch self {
        case .pane: return true
        case .split(_, _, let ratio, let first, let second):
            return ratio.isFinite && (0.1...0.9).contains(ratio)
                && first.isValid(depth: depth + 1) && second.isValid(depth: depth + 1)
        }
    }
}

struct WorkspaceTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var layout: PaneLayout
    var activePaneID: UUID
}

struct WorkspaceSnapshot: Identifiable, Codable, Equatable {
    struct Session: Codable, Equatable {
        let id: UUID
        let directory: String
        let customTitle: String?
    }
    var id: UUID
    var name: String
    var tabs: [WorkspaceTab]
    var sessions: [Session]
    var selectedID: UUID?
    var focusMode: Bool
    var windowFrame: String?

    var isValid: Bool {
        guard name.count <= 160, tabs.count <= 64, sessions.count <= 128,
              tabs.allSatisfy({ $0.layout.isValid() && $0.layout.sessionIDs.count <= 8 }),
              Set(tabs.map(\.id)).count == tabs.count else { return false }
        let leaves = tabs.flatMap { $0.layout.sessionIDs }
        let ids = sessions.map(\.id)
        let splits = tabs.flatMap { $0.layout.splitIDs }
        return Set(splits).count == splits.count && Set(leaves).count == leaves.count && Set(ids).count == ids.count
            && Set(leaves) == Set(ids)
            && tabs.allSatisfy { $0.layout.sessionIDs.contains($0.activePaneID) }
            && (selectedID == nil || ids.contains(selectedID!))
            && sessions.allSatisfy { $0.directory.hasPrefix("/") && $0.directory.count <= 4096 && ($0.customTitle?.count ?? 0) <= 160 }
    }
}
