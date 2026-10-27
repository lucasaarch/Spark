import AppKit
import SwiftUI

/// Native split views own geometry. Each pane keeps its hosting view and PTY
/// across selection, divider moves and changes to the surrounding split tree.
struct WorkspaceTerminalHost: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.update(view) }

    @MainActor
    final class Coordinator {
        private let workspace: Workspace
        private var panes: [UUID: NSHostingView<SessionPane>] = [:]
        private var splits: [UUID: WorkspaceSplitView] = [:]
        private var selectedID: UUID?

        init(workspace: Workspace) { self.workspace = workspace }

        func update(_ container: NSView) {
            let live = Set(workspace.sessions.map(\.id))
            for id in Array(panes.keys) where !live.contains(id) { panes.removeValue(forKey: id)?.removeFromSuperview() }
            var usedSplits = Set<UUID>()
            var roots: [NSView] = []
            for tab in workspace.tabs {
                let root = makeView(tab.layout, usedSplits: &usedSplits)
                if root.superview !== container {
                    root.removeFromSuperview()
                    root.frame = container.bounds
                    root.autoresizingMask = [.width, .height]
                    container.addSubview(root)
                }
                root.isHidden = tab.id != workspace.selectedTab?.id
                roots.append(root)
            }
            for child in container.subviews where !roots.contains(where: { $0 === child }) { child.removeFromSuperview() }
            for id in Array(splits.keys) where !usedSplits.contains(id) { splits.removeValue(forKey: id)?.removeFromSuperview() }
            let needsFocus = selectedID != workspace.selectedID
            selectedID = workspace.selectedID
            DispatchQueue.main.async { [weak workspace] in
                guard let workspace else { return }
                workspace.window?.contentView?.layoutSubtreeIfNeeded()
                for session in workspace.sessions where workspace.visibleSessionIDs.contains(session.id) && session.terminal.window != nil {
                    session.start()
                }
                if needsFocus, let terminal = workspace.selected?.terminal, terminal.window != nil {
                    terminal.window?.makeFirstResponder(terminal)
                }
            }
        }

        private func makeView(_ layout: PaneLayout, usedSplits: inout Set<UUID>) -> NSView {
            switch layout {
            case .pane(let id):
                if let pane = panes[id] { return pane }
                guard let session = workspace.sessions.first(where: { $0.id == id }) else { return NSView() }
                let pane = NSHostingView(rootView: SessionPane(session: session, workspace: workspace))
                pane.sizingOptions = []
                panes[id] = pane
                return pane
            case .split(let id, let axis, let ratio, let first, let second):
                usedSplits.insert(id)
                let split = splits[id] ?? WorkspaceSplitView()
                splits[id] = split
                split.onRatioChanged = { [weak workspace] ratio in workspace?.setRatio(ratio, splitID: id) }
                let children = [makeView(first, usedSplits: &usedSplits), makeView(second, usedSplits: &usedSplits)]
                split.configure(axis: axis, ratio: ratio, children: children)
                return split
            }
        }
    }
}

final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    var onRatioChanged: ((Double) -> Void)?
    private var ratio = 0.5
    private var updating = false

    init() {
        super.init(frame: .zero)
        dividerStyle = .thin
        delegate = self
        setAccessibilityLabel("Resize terminal panes")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var dividerThickness: CGFloat { 8 }
    override func drawDivider(in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.08).setFill()
        let line = isVertical ? NSRect(x: rect.midX, y: rect.minY + 12, width: 1, height: max(0, rect.height - 24))
            : NSRect(x: rect.minX + 12, y: rect.midY, width: max(0, rect.width - 24), height: 1)
        line.fill()
    }

    func configure(axis: SplitAxis, ratio: Double, children: [NSView]) {
        updating = true
        defer { updating = false }
        isVertical = axis == .vertical
        self.ratio = ratio
        if arrangedSubviews.count != children.count || zip(arrangedSubviews, children).contains(where: { $0 !== $1 }) {
            for child in arrangedSubviews { child.removeFromSuperview() }
            for child in children { child.removeFromSuperview(); addArrangedSubview(child) }
        }
        resizeSubviews(withOldSize: bounds.size)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2 else { return }
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        let firstSize = available * ratio
        if isVertical {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: firstSize, height: bounds.height)
            arrangedSubviews[1].frame = NSRect(x: firstSize + dividerThickness, y: 0, width: available - firstSize, height: bounds.height)
        } else {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstSize)
            arrangedSubviews[1].frame = NSRect(x: 0, y: firstSize + dividerThickness, width: bounds.width, height: available - firstSize)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        return min(available * 0.9, max(available * 0.1, proposedPosition))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Accessibility resizing also changes the divider without the mouse-drag
        // flag. Persist every native divider change outside our own layout pass.
        guard !updating, let first = arrangedSubviews.first else { return }
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard available > 0 else { return }
        ratio = min(0.9, max(0.1, (isVertical ? first.frame.width : first.frame.height) / available))
        let value = ratio
        DispatchQueue.main.async { [weak self] in self?.onRatioChanged?(value) }
    }
}
