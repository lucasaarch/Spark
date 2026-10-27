import AppKit
import SwiftUI
import Sparkle

@main
struct SparkApp {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--claude-status" {
            ClaudeStatusBridge.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [TerminalWindowController] = []
    private var workspaceCache: [UUID: Workspace] = [:]
    private var workspaceOrder: [UUID] = []
    private let catalog: WorkspaceStore = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPARK_UI_TESTING"] == "1" { return WorkspaceStore() }
        #endif
        return WorkspaceStore(fileURL: WorkspaceStore.defaultURL)
    }()
    private lazy var notifications = AgentNotifications()
    private var terminating = false
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var workspace: Workspace? { (NSApp.keyWindow?.windowController as? TerminalWindowController)?.workspace }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["fontSize": 14.0, "optionAsMeta": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
        // Unit tests load this executable as their host; do not spawn an unrelated login shell.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        _ = updater
        workspaceOrder = catalog.openIDs
        catalog.openWorkspace = { [weak self] id in self?.switchWorkspace(id) }
        catalog.createWorkspace = { [weak self] name in self?.createWorkspace(name: name) }
        notifications.isViewingSession = { [weak self] workspaceID, sessionID in
            guard NSApp.isActive, let controller = self?.windows.first(where: { $0.workspace.id == workspaceID }),
                  let window = controller.window else { return false }
            return window.isKeyWindow && !window.isMiniaturized && window.occlusionState.contains(.visible)
                && controller.workspace.selectedID == sessionID
        }
        notifications.activateSession = { [weak self] workspaceID, sessionID in
            guard let self else { return }
            // A stale notification must not manufacture a missing session.
            let exists = self.workspaceCache[workspaceID]?.sessions.contains { $0.id == sessionID } == true
                || self.catalog.workspaces.contains { $0.id == workspaceID && $0.sessions.contains { $0.id == sessionID } }
            guard exists else { return }
            self.switchWorkspace(workspaceID)
            if let workspace = self.workspaceCache[workspaceID],
               let session = workspace.sessions.first(where: { $0.id == sessionID }),
               let controller = NSApp.keyWindow?.windowController as? TerminalWindowController ?? self.windows.first {
                workspace.select(session)
                controller.window?.makeFirstResponder(session.terminal)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let ids = catalog.openIDs.isEmpty ? Array(catalog.workspaces.suffix(1).map(\.id)) : catalog.openIDs
        if ids.isEmpty { newWindow(nil) } else { ids.forEach { openWorkspace($0) } }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWorkspace(workspaceOrder.last ?? catalog.workspaces.last?.id) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspaceCache.values.contains(where: \.hasActiveCommands) && !Workspace.confirmClose() { return .terminateCancel }
        terminating = true
        workspaceCache.values.forEach { catalog.save($0.snapshot()) }
        catalog.setOpenIDs(workspaceOrder.filter { workspaceCache[$0] != nil })
        catalog.flush()
        workspaceCache.values.forEach { $0.stopAll() }
        windows.forEach { $0.prepareForTermination() }
        return .terminateNow
    }

    @objc func newWindow(_ sender: Any?) {
        let workspace = Workspace(name: "Workspace \(catalog.workspaces.count + 1)")
        remember(workspace)
        showWindow(for: workspace)
    }

    private func openWorkspace(_ id: UUID?) {
        let workspace = workspace(for: id)
        if let controller = windows.first {
            controller.switchWorkspace(to: workspace)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            catalog.setOpenIDs(workspaceOrder)
        } else { showWindow(for: workspace) }
    }

    private func switchWorkspace(_ id: UUID?) {
        guard let id else { return }
        let workspace = workspace(for: id)
        if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController ?? windows.first {
            controller.switchWorkspace(to: workspace)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else { showWindow(for: workspace) }
        catalog.setOpenIDs(workspaceOrder)
    }

    private func createWorkspace(name: String) {
        let workspace = Workspace(name: AgentMetrics.clean(name) ?? "Workspace")
        remember(workspace)
        if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController ?? windows.first {
            controller.switchWorkspace(to: workspace)
        } else { showWindow(for: workspace) }
        catalog.setOpenIDs(workspaceOrder)
    }

    private func workspace(for id: UUID?) -> Workspace {
        if let id, let cached = workspaceCache[id] { return cached }
        let snapshot = catalog.workspaces.first { $0.id == id }
        let workspace = Workspace(snapshot: snapshot, name: "Workspace \(catalog.workspaces.count + 1)")
        remember(workspace)
        return workspace
    }

    private func remember(_ workspace: Workspace) {
        if workspaceCache[workspace.id] == nil { workspaceOrder.append(workspace.id) }
        workspaceCache[workspace.id] = workspace
    }

    private func showWindow(for workspace: Workspace) {
        let controller = TerminalWindowController(frameName: "SparkWorkspace-" + workspace.id.uuidString,
            workspace: workspace, catalog: catalog, notifications: notifications, restoredFrame: workspace.lastWindowFrame)
        controller.onClose = { [weak self, weak controller] in
            guard let self, !self.terminating else { return }
            if let id = controller?.workspace.id {
                self.workspaceCache.removeValue(forKey: id)
                self.workspaceOrder.removeAll { $0 == id }
            }
            self.windows.removeAll { $0 === controller }
            self.catalog.setOpenIDs(self.workspaceOrder.filter { self.workspaceCache[$0] != nil })
            self.catalog.flush()
            if self.windows.isEmpty && self.workspaceCache.isEmpty { NSApp.terminate(nil) }
        }
        windows.append(controller)
        catalog.save(workspace.snapshot())
        catalog.setOpenIDs(workspaceOrder.filter { workspaceCache[$0] != nil })
        controller.showWindow(nil)
    }
    @objc private func splitRight(_ sender: Any?) { workspace?.split(.vertical) }
    @objc private func splitBelow(_ sender: Any?) { workspace?.split(.horizontal) }
    @objc private func nextPane(_ sender: Any?) { workspace?.selectNextPane() }
    @objc private func newTab(_ sender: Any?) { if let workspace { workspace.add() } else { newWindow(nil) } }
    @objc private func closeTab(_ sender: Any?) { if let session = workspace?.selected { workspace?.close(session) } }
    @objc private func openFolder(_ sender: Any?) { workspace?.openDirectory() }
    @objc private func settings(_ sender: Any?) { if workspace == nil { newWindow(nil) }; workspace?.showsSettings = true }
    @objc private func updates(_ sender: Any?) { updater.checkForUpdates(sender) }
    @objc private func nextTab(_ sender: Any?) { workspace?.selectNext(1) }
    @objc private func previousTab(_ sender: Any?) { workspace?.selectNext(-1) }
    @objc private func focusMode(_ sender: Any?) { workspace?.focusMode.toggle() }
    @objc private func bigger(_ sender: Any?) { workspace?.changeFontSize(by: 1) }
    @objc private func smaller(_ sender: Any?) { workspace?.changeFontSize(by: -1) }
    @objc private func resetSize(_ sender: Any?) { UserDefaults.standard.set(14.0, forKey: "fontSize"); workspace?.applyPreferences() }
    @objc private func find(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        workspace?.selected?.terminal.performTextFinderAction(item)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(splitRight(_:)), #selector(splitBelow(_:))].contains(menuItem.action) { return workspace?.canSplit == true }
        if menuItem.action == #selector(nextPane(_:)) { return (workspace?.visibleSessionIDs.count ?? 0) > 1 }
        if menuItem.action == #selector(updates(_:)) { return updater.updater.canCheckForUpdates }
        if [#selector(newWindow(_:)), #selector(newTab(_:)), #selector(settings(_:))].contains(menuItem.action) { return true }
        return workspace != nil
    }

    private func buildMenu() {
        let menu = NSMenu()
        func section(_ name: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: name)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        let app = section("Spark")
        item(app, "About Spark", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "Settings…", #selector(settings(_:)), ",", target: self)
        item(app, "Check for Updates…", #selector(updates(_:)), target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item(app, "Hide Spark", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        item(app, "Quit Spark", #selector(NSApplication.terminate(_:)), "q")
        let shell = section("Shell")
        item(shell, "New Window", #selector(newWindow(_:)), "n", target: self)
        item(shell, "New Tab", #selector(newTab(_:)), "t", target: self)
        item(shell, "Open Folder…", #selector(openFolder(_:)), "o", target: self)
        shell.addItem(.separator())
        item(shell, "Split Right", #selector(splitRight(_:)), "d", target: self)
        item(shell, "Split Below", #selector(splitBelow(_:)), "d", [.command, .shift], target: self)
        item(shell, "Next Pane", #selector(nextPane(_:)), "\t", [.control], target: self)
        shell.addItem(.separator())
        item(shell, "Close Pane or Tab", #selector(closeTab(_:)), "w", target: self)
        item(shell, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        let edit = section("Edit")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find…", #selector(find(_:)), "f", target: self)
        let view = section("View")
        item(view, "Increase Text Size", #selector(bigger(_:)), "=", target: self)
        item(view, "Decrease Text Size", #selector(smaller(_:)), "-", target: self)
        item(view, "Reset Text Size", #selector(resetSize(_:)), "0", target: self)
        view.addItem(.separator())
        item(view, "Toggle Focus Mode", #selector(focusMode(_:)), "f", [.command, .shift], target: self)
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let window = section("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        item(window, "Next Tab", #selector(nextTab(_:)), "]", [.command, .shift], target: self)
        item(window, "Previous Tab", #selector(previousTab(_:)), "[", [.command, .shift], target: self)
        NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var workspace: Workspace
    private let catalog: WorkspaceStore
    private let notifications: AgentNotifications
    var onClose: (() -> Void)?
    private let frameName: NSWindow.FrameAutosaveName
    private var terminating = false

    init(frameName: NSWindow.FrameAutosaveName = "SparkTerminalWindow", workspace: Workspace? = nil,
         catalog: WorkspaceStore? = nil, notifications: AgentNotifications? = nil, restoredFrame: String? = nil) {
        self.frameName = frameName
        self.workspace = workspace ?? Workspace()
        self.catalog = catalog ?? WorkspaceStore()
        self.notifications = notifications ?? AgentNotifications()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Spark — " + self.workspace.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        shouldCascadeWindows = false
        if self.workspace.sessions.isEmpty { self.workspace.add() }
        window.contentView = NSHostingView(rootView: ContentView(workspace: self.workspace, catalog: self.catalog, notifications: self.notifications))
        // Restore after installing content, and never center over a saved frame.
        if let restoredFrame {
            let frame = NSRectFromString(restoredFrame)
            if frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
               frame.width >= 620, frame.height >= 400,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                var visible = frame
                visible.size.width = min(frame.width, screen.visibleFrame.width)
                visible.size.height = min(frame.height, screen.visibleFrame.height)
                visible.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - visible.width)
                visible.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - visible.height)
                window.setFrame(visible, display: false)
            } else { window.center() }
        } else if !window.setFrameUsingName(frameName), !window.setFrameUsingName("SparkTerminalWindow") { window.center() }
        window.setFrameAutosaveName(frameName)
        self.workspace.lastWindowFrame = NSStringFromRect(window.frame)
        window.delegate = self
        installWorkspace(self.workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func switchWorkspace(to next: Workspace) {
        guard next.id != workspace.id, let window else { return }
        saveFrame()
        catalog.save(workspace.snapshot())
        workspace.window = nil
        workspace = next
        workspace.window = window
        window.title = "Spark — " + workspace.name
        if workspace.sessions.isEmpty { workspace.add() }
        window.contentView = NSHostingView(rootView: ContentView(workspace: workspace, catalog: catalog, notifications: notifications))
        installWorkspace(workspace)
        catalog.save(workspace.snapshot())
        if let frame = workspace.lastWindowFrame {
            let rect = NSRectFromString(frame)
            if rect.width >= 620, rect.height >= 400, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                window.setFrame(rect, display: true, animate: false)
            }
        }
    }

    private func installWorkspace(_ workspace: Workspace) {
        workspace.window = window
        workspace.onChange = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            if self.workspace.id == workspace.id { self.window?.title = "Spark — " + workspace.name }
            self.catalog.save(workspace.snapshot())
        }
        workspace.onAgentChange = { [weak self, weak workspace] session, activity in
            guard let self, let workspace else { return }
            self.notifications.observe(activity, session: session, workspaceID: workspace.id)
        }
        workspace.onSessionRemoved = { [weak self] id in self?.notifications.removeSession(id) }
        workspace.onLastTerminalExit = {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !workspace.hasActiveCommands || Workspace.confirmClose()
    }
    func windowWillClose(_ notification: Notification) {
        let closingWorkspace = workspace
        if !terminating {
            saveFrame()
            catalog.save(closingWorkspace.snapshot())
            catalog.flush()
        }
        closingWorkspace.window = nil
        closingWorkspace.stopAll()
        onClose?()
    }

    func prepareForTermination() {
        terminating = true
        workspace.onChange = nil
        workspace.stopAll()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard !terminating, let window, !window.styleMask.contains(.fullScreen) else { return }
        // AppKit permits only one live window to own an autosave name. Explicit
        // saves also remember the last frame when another Spark window moves.
        window.saveFrame(usingName: frameName)
        workspace.lastWindowFrame = NSStringFromRect(window.frame)
        catalog.save(workspace.snapshot())
    }
}
