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
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var workspace: Workspace? { (NSApp.keyWindow?.windowController as? TerminalWindowController)?.workspace }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["fontSize": 14.0, "optionAsMeta": false])
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
        // Unit tests load this executable as their host; do not spawn an unrelated login shell.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        _ = updater
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if windows.contains(where: { $0.workspace.hasRunningSessions }) && !Workspace.confirmClose() { return .terminateCancel }
        windows.forEach { $0.workspace.stopAll() }
        return .terminateNow
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = TerminalWindowController()
        controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
        windows.append(controller)
        controller.showWindow(nil)
    }
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
        item(shell, "Close Tab", #selector(closeTab(_:)), "w", target: self)
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
    let workspace = Workspace()
    var onClose: (() -> Void)?
    private let frameName: NSWindow.FrameAutosaveName

    init(frameName: NSWindow.FrameAutosaveName = "SparkTerminalWindow") {
        self.frameName = frameName
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Spark"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        shouldCascadeWindows = false
        workspace.window = window
        workspace.add()
        window.contentView = NSHostingView(rootView: ContentView(workspace: workspace))
        // Restore after installing content, and never center over a saved frame.
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !workspace.hasRunningSessions || Workspace.confirmClose()
    }
    func windowWillClose(_ notification: Notification) {
        saveFrame()
        workspace.stopAll()
        onClose?()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        // AppKit permits only one live window to own an autosave name. Explicit
        // saves also remember the last frame when another Spark window moves.
        window.saveFrame(usingName: frameName)
    }
}
