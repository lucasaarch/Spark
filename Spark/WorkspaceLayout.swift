import Foundation

enum SplitAxis: String, Codable { case horizontal, vertical }

enum PaneDropZone: Equatable {
    case leading, trailing, top, bottom

    var axis: SplitAxis { self == .leading || self == .trailing ? .vertical : .horizontal }
    var placesSourceFirst: Bool { self == .leading || self == .bottom }

    func rect(in size: CGSize) -> CGRect {
        switch self {
        case .leading: CGRect(x: 0, y: 0, width: size.width * 0.38, height: size.height)
        case .trailing: CGRect(x: size.width * 0.62, y: 0, width: size.width * 0.38, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.38)
        case .bottom: CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38)
        }
    }

    static func at(_ point: CGPoint, in size: CGSize) -> PaneDropZone {
        let horizontal = size.width > 0 ? point.x / size.width : 0.5
        let vertical = size.height > 0 ? point.y / size.height : 0.5
        let distances: [(PaneDropZone, CGFloat)] = [
            (.leading, horizontal), (.trailing, 1 - horizontal), (.top, vertical), (.bottom, 1 - vertical)
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .leading
    }
}

struct PaneDropPreview: Equatable {
    let targetID: UUID
    let zone: PaneDropZone
}

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
            return .split(
                id: id, axis: direction, ratio: ratio,
                first: first.splitting(target, with: newID, axis: axis),
                second: second.splitting(target, with: newID, axis: axis))
        }
    }

    func moving(_ source: UUID, onto target: UUID, zone: PaneDropZone) -> PaneLayout? {
        guard source != target, sessionIDs.contains(source), sessionIDs.contains(target),
            let remaining = removing(source),
            let result = remaining.inserting(source, beside: target, zone: zone),
            result.isValid()
        else { return nil }
        return result
    }

    func adding(_ source: UUID, beside target: UUID, zone: PaneDropZone) -> PaneLayout? {
        guard !sessionIDs.contains(source), sessionIDs.contains(target),
            let result = inserting(source, beside: target, zone: zone), result.isValid()
        else { return nil }
        return result
    }

    private func inserting(_ source: UUID, beside target: UUID, zone: PaneDropZone) -> PaneLayout? {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            let sourcePane = PaneLayout.pane(source)
            return .split(
                id: UUID(), axis: zone.axis, ratio: 0.5,
                first: zone.placesSourceFirst ? sourcePane : self,
                second: zone.placesSourceFirst ? self : sourcePane)
        case .split(let id, let axis, let ratio, let first, let second):
            guard let movedFirst = first.inserting(source, beside: target, zone: zone) else { return nil }
            if movedFirst != first {
                return .split(id: id, axis: axis, ratio: ratio, first: movedFirst, second: second)
            }
            guard let movedSecond = second.inserting(source, beside: target, zone: zone) else { return nil }
            return .split(id: id, axis: axis, ratio: ratio, first: first, second: movedSecond)
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
            return .split(
                id: id, axis: axis, ratio: id == target ? min(0.9, max(0.1, value)) : ratio,
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

enum PanePreset: CaseIterable, Identifiable {
    case twoColumns, twoRows, threeColumns, mainAndTwoRows, gridFour, mainAndThreeRows

    var id: Self { self }
    var name: String {
        switch self {
        case .twoColumns: "Two Columns"
        case .twoRows: "Two Rows"
        case .threeColumns: "Three Columns"
        case .mainAndTwoRows: "Main and Two Stacked"
        case .gridFour: "Grid of Four"
        case .mainAndThreeRows: "Main and Three Stacked"
        }
    }
    var glyph: String {
        switch self {
        case .twoColumns: "▯│▯"
        case .twoRows: "▱─▱"
        case .threeColumns: "▯│▯│▯"
        case .mainAndTwoRows: "▰│▱"
        case .gridFour: "▱▱"
        case .mainAndThreeRows: "▰│▱"
        }
    }
    var extraCount: Int {
        switch self {
        case .twoColumns, .twoRows: 1
        case .threeColumns, .mainAndTwoRows: 2
        case .gridFour, .mainAndThreeRows: 3
        }
    }
    private var layout: Layout {
        switch self {
        case .twoColumns: .split(.vertical, 0.5, .current, .extra(0))
        case .twoRows: .split(.horizontal, 0.5, .current, .extra(0))
        case .threeColumns:
            .split(.vertical, 1.0 / 3.0, .current, .split(.vertical, 0.5, .extra(0), .extra(1)))
        case .mainAndTwoRows:
            .split(.vertical, 2.0 / 3.0, .current, .split(.horizontal, 0.5, .extra(0), .extra(1)))
        case .gridFour:
            .split(
                .vertical, 0.5,
                .split(.horizontal, 0.5, .current, .extra(0)),
                .split(.horizontal, 0.5, .extra(1), .extra(2)))
        case .mainAndThreeRows:
            .split(
                .vertical, 2.0 / 3.0, .current,
                .split(.horizontal, 1.0 / 3.0, .extra(0), .split(.horizontal, 0.5, .extra(1), .extra(2))))
        }
    }

    func makeLayout(current: UUID, extras: [UUID]) -> PaneLayout {
        layout.build(current: current, extras: extras)
    }

    private indirect enum Layout {
        case current, extra(Int), split(SplitAxis, Double, Layout, Layout)

        func build(current: UUID, extras: [UUID]) -> PaneLayout {
            switch self {
            case .current: .pane(current)
            case .extra(let index): .pane(extras[index])
            case .split(let axis, let ratio, let first, let second):
                .split(
                    id: UUID(), axis: axis, ratio: ratio,
                    first: first.build(current: current, extras: extras),
                    second: second.build(current: current, extras: extras))
            }
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
        var conversation: AgentConversation?
        var worktree: WorktreeRecord?
    }
    var id: UUID
    var name: String
    var tabs: [WorkspaceTab]
    var sessions: [Session]
    var selectedID: UUID?
    var focusMode: Bool
    var windowFrame: String?
    var conversations: [AgentConversation]?

    var isValid: Bool {
        guard name.count <= 160, tabs.count <= 64, sessions.count <= 128,
            (conversations?.count ?? 0) <= 100, conversations?.allSatisfy(\.isValid) ?? true,
            tabs.allSatisfy({ $0.layout.isValid() && $0.layout.sessionIDs.count <= 8 }),
            Set(tabs.map(\.id)).count == tabs.count
        else { return false }
        let leaves = tabs.flatMap { $0.layout.sessionIDs }
        let ids = sessions.map(\.id)
        let splits = tabs.flatMap { $0.layout.splitIDs }
        return Set(splits).count == splits.count && Set(leaves).count == leaves.count && Set(ids).count == ids.count
            && Set(leaves) == Set(ids)
            && tabs.allSatisfy { $0.layout.sessionIDs.contains($0.activePaneID) }
            && (selectedID == nil || ids.contains(selectedID!))
            && sessions.allSatisfy {
                $0.directory.hasPrefix("/") && $0.directory.count <= 4096 && ($0.customTitle?.count ?? 0) <= 160
                    && ($0.conversation?.isValid ?? true) && ($0.worktree?.isValid ?? true)
            }
    }
}
