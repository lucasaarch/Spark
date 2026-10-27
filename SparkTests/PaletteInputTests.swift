import AppKit
import SwiftUI
import Testing
@testable import Spark

@MainActor
struct PaletteInputTests {
    @Test func nativeFieldEditorRoutesNavigationSubmitAndCancel() async throws {
        var query = ""
        var movements: [Int] = []
        var submissions = 0, cancellations = 0
        let host = NSHostingView(
            rootView: PaletteSearchField(
                text: Binding(get: { query }, set: { query = $0 }),
                move: { movements.append($0) }, submit: { submissions += 1 }, cancel: { cancellations += 1 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(findField(host))
        #expect(window.firstResponder is NSTextView)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("repo", replacementRange: NSRange(location: 0, length: 0))
        #expect(query == "repo")
        for selector in [
            #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.scrollPageUp(_:)),
            #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))
        ] {
            editor.doCommand(by: selector)
        }
        #expect(movements == [1, -1, 8, -8])
        #expect(submissions == 1 && cancellations == 1)
        #expect(query == "repo")
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(query == "rep")
    }

    @Test func keyboardSelectionExecutesTheChosenActionOnce() async throws {
        let workspace = Workspace()
        defer { workspace.stopAll() }
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SparkPalette-" + UUID().uuidString + ".json")
        let catalog = WorkspaceStore(fileURL: storeURL)
        workspace.showsCommandPalette = true
        let host = NSHostingView(rootView: CommandPalette(workspace: workspace, catalog: catalog))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let field = try #require(findField(host))
        let editor = try #require(field.currentEditor() as? NSTextView)
        // With no terminals, Activity is first and New Tab is second.
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await Task.sleep(for: .milliseconds(100))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(workspace.tabs.count == 1)
        #expect(!workspace.showsCommandPalette)
        workspace.showsCommandPalette = true
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!workspace.showsCommandPalette)
        #expect(workspace.tabs.count == 1)
    }

    private func findField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { findField($0) }.first
    }
}
