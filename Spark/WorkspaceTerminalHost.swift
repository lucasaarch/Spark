import AppKit
import SwiftUI

/// Native split views own geometry. Each pane keeps its hosting view and PTY
/// across selection, divider moves and changes to the surrounding split tree.
struct WorkspaceTerminalHost: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var workspace: Workspace
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> NSView { context.coordinator.makeContainer() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(view, reduceMotion: reduceMotion)
    }

    @MainActor
    final class Coordinator {
        private let workspace: Workspace
        private var panes: [UUID: NSHostingView<SessionPane>] = [:]
        private var splits: [UUID: WorkspaceSplitView] = [:]
        private var selectedID: UUID?
        private var paneLayoutAnimationID: UUID

        init(workspace: Workspace) {
            self.workspace = workspace
            paneLayoutAnimationID = workspace.paneLayoutAnimationID
        }

        func makeContainer() -> NSView {
            let container = PaneDropContainer()
            installDropHandling(on: container)
            return container
        }

        private func installDropHandling(on container: PaneDropContainer) {
            container.onDraggingUpdated = { [weak self, weak container] info in
                guard let self, let container else { return [] }
                return self.updateDropPreview(info, in: container)
            }
            container.onDraggingExited = { [weak self] in self?.workspace.paneDrag.clearPreview() }
            container.onPrepareDrop = { [weak self] info in self?.canPerformDrop(info) ?? false }
            container.onPerformDrop = { [weak self] info in self?.performDrop(info) ?? false }
        }

        private func updateDropPreview(_ info: NSDraggingInfo, in container: NSView) -> NSDragOperation {
            let pasteboardType = NSPasteboard.PasteboardType(PaneDragState.contentType.identifier)
            guard let source = workspace.paneDrag.sourceID,
                info.draggingPasteboard.availableType(from: [pasteboardType]) != nil,
                let window = container.window
            else {
                workspace.paneDrag.clearPreview()
                return []
            }
            let windowPoint = window.convertPoint(fromScreen: info.draggingLocation)
            let containerPoint = container.convert(windowPoint, from: nil)
            for id in workspace.visibleSessionIDs {
                guard let pane = panes[id] else { continue }
                let point = pane.convert(containerPoint, from: container)
                guard pane.bounds.contains(point), workspace.canMovePane(source, onto: id) else { continue }
                let y = pane.isFlipped ? point.y - pane.bounds.minY : pane.bounds.maxY - point.y
                let size = pane.bounds.size
                workspace.paneDrag.showPreview(
                    PaneDropPreview(
                        targetID: id,
                        zone: .at(CGPoint(x: point.x - pane.bounds.minX, y: y), in: size)))
                return .move
            }
            workspace.paneDrag.clearPreview()
            return []
        }

        private func canPerformDrop(_ info: NSDraggingInfo) -> Bool {
            guard let source = workspace.paneDrag.sourceID,
                let preview = workspace.paneDrag.preview,
                let value = draggedPaneID(in: info)
            else { return false }
            return UUID(uuidString: value) == source && workspace.canMovePane(source, onto: preview.targetID)
        }

        private func performDrop(_ info: NSDraggingInfo) -> Bool {
            guard canPerformDrop(info), let source = workspace.paneDrag.sourceID,
                let preview = workspace.paneDrag.preview
            else { return false }
            return workspace.movePane(source, onto: preview.targetID, zone: preview.zone)
        }

        private func draggedPaneID(in info: NSDraggingInfo) -> String? {
            let type = NSPasteboard.PasteboardType(PaneDragState.contentType.identifier)
            guard let data = info.draggingPasteboard.data(forType: type) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func update(_ container: NSView, reduceMotion: Bool) {
            var paneFrames: [UUID: NSRect] = [:]
            for (id, pane) in panes where pane.window != nil {
                paneFrames[id] = pane.convert(pane.bounds, to: nil)
            }
            let animatePaneMove = paneLayoutAnimationID != workspace.paneLayoutAnimationID
            paneLayoutAnimationID = workspace.paneLayoutAnimationID
            let live = Set(workspace.sessions.map(\.id))
            for id in Array(panes.keys) where !live.contains(id) {
                panes.removeValue(forKey: id)?.removeFromSuperview()
            }
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
            for child in container.subviews where !roots.contains(where: { $0 === child }) {
                child.removeFromSuperview()
            }
            for id in Array(splits.keys) where !usedSplits.contains(id) {
                splits.removeValue(forKey: id)?.removeFromSuperview()
            }
            let needsFocus = selectedID != workspace.selectedID
            selectedID = workspace.selectedID
            DispatchQueue.main.async { [weak workspace] in
                guard let workspace else { return }
                workspace.window?.contentView?.layoutSubtreeIfNeeded()
                if animatePaneMove { self.animatePaneMoves(from: paneFrames, reduceMotion: reduceMotion) }
                for session in workspace.sessions
                where workspace.visibleSessionIDs.contains(session.id) && session.terminal.window != nil {
                    session.start()
                }
                if needsFocus, let terminal = workspace.selected?.terminal, terminal.window != nil {
                    terminal.window?.makeFirstResponder(terminal)
                }
            }
        }

        private func animatePaneMoves(from oldFrames: [UUID: NSRect], reduceMotion: Bool) {
            for (id, oldFrame) in oldFrames {
                guard let pane = panes[id], let parent = pane.superview else { continue }
                let targetFrame = pane.frame
                if reduceMotion { pane.frame = targetFrame; continue }
                pane.frame = parent.convert(oldFrame, from: nil)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    pane.animator().setFrameOrigin(targetFrame.origin)
                    pane.animator().setFrameSize(targetFrame.size)
                }
            }
        }

        private func makeView(_ layout: PaneLayout, usedSplits: inout Set<UUID>) -> NSView {
            switch layout {
            case .pane(let id):
                if let pane = panes[id] { return pane }
                guard let session = workspace.sessions.first(where: { $0.id == id }) else { return NSView() }
                let pane = NSHostingView(
                    rootView: SessionPane(session: session, workspace: workspace, paneDrag: workspace.paneDrag))
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

private final class PaneDropContainer: NSView {
    var onDraggingUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onDraggingExited: (() -> Void)?
    var onPrepareDrop: ((NSDraggingInfo) -> Bool)?
    var onPerformDrop: ((NSDraggingInfo) -> Bool)?

    init() {
        super.init(frame: .zero)
        let type = NSPasteboard.PasteboardType(PaneDragState.contentType.identifier)
        registerForDraggedTypes([type])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingUpdated?(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingUpdated?(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDraggingExited?() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPrepareDrop?(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDrop?(sender) ?? false
    }
}

final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    var onRatioChanged: ((Double) -> Void)?
    private var ratio = 0.5
    private var updating = false

    init() {
        super.init(frame: .zero)
        dividerStyle = .thin
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        delegate = self
        setAccessibilityLabel("Resize terminal panes")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var dividerThickness: CGFloat { 12 }
    override func drawDivider(in rect: NSRect) {}

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
            arrangedSubviews[1].frame = NSRect(
                x: firstSize + dividerThickness, y: 0, width: available - firstSize, height: bounds.height)
        } else {
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstSize)
            arrangedSubviews[1].frame = NSRect(
                x: 0, y: firstSize + dividerThickness, width: bounds.width, height: available - firstSize)
        }
    }

    func splitView(
        _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
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
