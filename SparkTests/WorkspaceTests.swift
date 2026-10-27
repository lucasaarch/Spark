import AppKit
import Testing
@testable import Spark

@MainActor
struct WorkspaceTests {
    @Test func nestedSplitsCollapseWithoutReplacingSurvivingTerminals() throws {
        let workspace = Workspace()
        defer { workspace.stopAll() }
        let first = workspace.add()
        let original = first.terminal
        let right = try #require(workspace.split(.vertical))
        let below = try #require(workspace.split(.horizontal))
        #expect(workspace.tabs.count == 1)
        #expect(workspace.visibleSessionIDs == [first.id, right.id, below.id])
        #expect(below.directory == first.directory)
        let otherTab = workspace.add()
        workspace.selectNext(-1)
        #expect(workspace.selected === below)
        workspace.remove(right)
        #expect(workspace.visibleSessionIDs == [first.id, below.id])
        #expect(first.terminal === original)
        workspace.remove(below)
        #expect(workspace.selected === first)
        #expect(workspace.selectedTab?.layout == .pane(first.id))
        workspace.remove(first)
        #expect(workspace.selected === otherTab)
        #expect(workspace.snapshot().isValid)
    }

    @Test func diskRoundTripRestoresMetadataLayoutAndSelectionWithFreshShells() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("workspaces.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = Workspace(name: "Payments")
        defer { workspace.stopAll() }
        let first = workspace.add(directory: FileManager.default.temporaryDirectory)
        first.customTitle = "Tests"
        let second = try #require(workspace.split(.vertical))
        if case .split(let id, _, _, _, _) = workspace.tabs[0].layout { workspace.setRatio(0.65, splitID: id) }
        workspace.add()
        workspace.select(second)
        workspace.focusMode = true
        let store = WorkspaceStore(fileURL: url)
        store.save(workspace.snapshot())
        store.setOpenIDs([workspace.id])
        store.flush()
        #expect(store.errorMessage == nil)
        let loaded = WorkspaceStore(fileURL: url)
        #expect(loaded.openIDs == [workspace.id])
        let saved = try #require(loaded.workspaces.first)
        let restored = Workspace(snapshot: saved)
        defer { restored.stopAll() }
        #expect(restored.id == workspace.id)
        #expect(restored.name == "Payments")
        #expect(restored.tabs == workspace.tabs)
        #expect(restored.selectedID == second.id)
        #expect(restored.sessions.first?.customTitle == "Tests")
        #expect(restored.sessions.first?.directory == first.directory)
        #expect(restored.focusMode)
        #expect(restored.sessions.allSatisfy { $0.status == .ready && !$0.terminal.process.running })
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("scrollback") && !text.contains("environment"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func closingWindowSavesBeforeStoppingItsSessions() throws {
        let catalog = WorkspaceStore()
        let workspace = Workspace(name: "Backend")
        let first = workspace.add()
        let controller = TerminalWindowController(frameName: UUID().uuidString, workspace: workspace, catalog: catalog)
        defer { controller.window?.setFrameAutosaveName("") }
        workspace.split(.horizontal)
        workspace.select(first)
        controller.close()
        #expect(workspace.sessions.isEmpty)
        let saved = try #require(catalog.workspaces.first)
        #expect(saved.sessions.count == 2)
        #expect(saved.selectedID == first.id)
        #expect(saved.windowFrame != nil)
        #expect(saved.isValid)
    }

    @Test func terminationCannotOverwriteSavedLayoutWithStoppedSessions() throws {
        let catalog = WorkspaceStore()
        let workspace = Workspace()
        workspace.add()
        workspace.split(.horizontal)
        let controller = TerminalWindowController(frameName: UUID().uuidString, workspace: workspace, catalog: catalog)
        defer { controller.window?.setFrameAutosaveName("") }
        catalog.save(workspace.snapshot())
        controller.prepareForTermination()
        controller.close()
        #expect(workspace.sessions.isEmpty)
        #expect(catalog.workspaces.first?.sessions.count == 2)
    }

    @Test func corruptOrNewerDocumentsArePreservedAndMissingFoldersFallBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data(#"{"version":999,"workspaces":[],"openIDs":[]}"#.utf8)
        try original.write(to: file)
        let store = WorkspaceStore(fileURL: file)
        #expect(store.errorMessage != nil)
        let workspace = Workspace()
        defer { workspace.stopAll() }
        workspace.add(directory: URL(fileURLWithPath: "/nonexistent-spark-test-" + UUID().uuidString))
        store.save(workspace.snapshot())
        store.flush()
        #expect(try Data(contentsOf: file) == original)
        let restored = Workspace(snapshot: workspace.snapshot())
        defer { restored.stopAll() }
        #expect(restored.selected?.directory == FileManager.default.homeDirectoryForCurrentUser)
        var invalid = workspace.snapshot()
        invalid.sessions += invalid.sessions
        #expect(!invalid.isValid)
    }

    @Test func nativePanesKeepPTYsThroughSplitTabSwitchAndClose() async throws {
        let workspace = Workspace()
        let controller = TerminalWindowController(frameName: UUID().uuidString, workspace: workspace)
        let window = try #require(controller.window)
        defer { workspace.stopAll(); controller.close(); window.setFrameAutosaveName("") }
        controller.showWindow(nil)
        let first = try #require(workspace.selected)
        try await wait { first.terminal.process.running }
        let pid = first.terminal.process.shellPid
        let second = try #require(workspace.split(.vertical))
        try await wait { second.terminal.process.running && second.terminal.bounds.width > 100 }
        #expect(first.terminal.process.shellPid == pid)
        #expect(first.terminal.bounds.width < window.frame.width * 0.7)
        #expect(second.terminal.bounds.width < window.frame.width * 0.7)
        var ancestor = first.terminal.superview
        while ancestor != nil && !(ancestor is WorkspaceSplitView) { ancestor = ancestor?.superview }
        let splitView = try #require(ancestor as? WorkspaceSplitView)
        splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) * 0.65, ofDividerAt: 0)
        try await wait {
            if case .split(_, _, let ratio, _, _) = workspace.tabs[0].layout { return abs(ratio - 0.65) < 0.01 }
            return false
        }
        let third = workspace.add()
        try await wait { third.terminal.process.running }
        workspace.select(first)
        try await wait { window.firstResponder === first.terminal }
        #expect(first.terminal.process.shellPid == pid)
        workspace.remove(second)
        try await wait { first.terminal.bounds.width > window.frame.width * 0.8 }
        #expect(first.terminal.process.shellPid == pid)
        first.terminal.send(data: Array("printf 'SURVIVING_PTY_OK\\n'\n".utf8)[...])
        try await wait {
            String(decoding: first.terminal.getBufferAsData(), as: UTF8.self).contains("SURVIVING_PTY_OK")
        }
    }

    @Test func restoredSplitWindowHasVisibleGeometryAndStartsEveryVisiblePane() async throws {
        let original = Workspace()
        original.add()
        original.split(.vertical)
        original.split(.horizontal)
        var saved = original.snapshot()
        original.stopAll()
        saved.windowFrame = "{{175, 113}, {1120, 772}}"
        let workspace = Workspace(snapshot: saved)
        let controller = TerminalWindowController(
            frameName: UUID().uuidString, workspace: workspace, restoredFrame: saved.windowFrame)
        let window = try #require(controller.window)
        defer { workspace.stopAll(); controller.close(); window.setFrameAutosaveName("") }
        controller.showWindow(nil)
        try await wait { workspace.sessions.allSatisfy { $0.terminal.process.running } }
        #expect(window.isVisible)
        #expect(window.frame.width >= 620 && window.frame.height >= 400)
        #expect(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) })
        #expect(workspace.sessions.allSatisfy { $0.terminal.bounds.width > 100 && $0.terminal.bounds.height > 100 })
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Expected native workspace state within six seconds")
    }
}
