import AppKit
import Testing
@testable import Spark

@MainActor
struct LaunchCompatibilityTests {
    @Test(arguments: ["cdx", "caveman codex", "command codex"])
    func aliasesAndDescendantProcessesReceiveMetrics(command: String) async throws {
        let fixture = try AgentMetricsTests.Fixture()
        defer { fixture.remove() }
        let rc = fixture.folder.appendingPathComponent(".zshrc")
        var startup = try String(contentsOf: rc, encoding: .utf8)
        startup += "\nalias cdx='caveman codex'\n"
        try startup.write(to: rc, atomically: true, encoding: .utf8)
        // Caveman resolves a binary on PATH and spawns it with inherited stdio.
        // An external process cannot see a zsh function; this exercises that seam.
        let wrapper = fixture.folder.appendingPathComponent("caveman")
        try "#!/bin/sh\nexec \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let codex = fixture.folder.appendingPathComponent("codex")
        var cli = try String(contentsOf: codex, encoding: .utf8)
        cli = cli.replacingOccurrences(of: "test \"$1\" = -c || exit 9", with: "test \"$1\" = -c || exit 9\ntest \"$3\" = --model || exit 8\ntest \"$4\" = 'model with spaces' || exit 8")
        cli += "\nexit 7\n"
        try cli.write(to: codex, atomically: false, encoding: .utf8)

        let session = TerminalSession(directory: fixture.folder, shell: "/bin/zsh")
        defer { session.stop() }
        session.start(environment: fixture.environment(percent: 10))
        try await wait { output(session).contains("STARTUP_READY") }
        session.terminal.send(data: Array("\(command) --model 'model with spaces'\n".utf8)[...])
        try await wait { session.metrics?.contextPercent == 37 }
        #expect(session.title == "Codex")
        #expect(session.agent?.provider == .codex)
        session.terminal.send(data: Array("exit\n".utf8)[...])
        try await wait { session.agent == nil && session.metrics == nil }
        session.terminal.send(data: Array("printf 'WRAPPER_EXIT:%s\\n' \"$?\"\n".utf8)[...])
        try await wait { output(session).contains("WRAPPER_EXIT:7") }
    }

    @Test func reopeningWindowRestoresSizeAndPositionInsteadOfCentering() throws {
        let name = "SparkFrameTest-" + UUID().uuidString
        let first = TerminalWindowController(frameName: name)
        let window = try #require(first.window)
        let screen = try #require(NSScreen.main).visibleFrame
        let expected = NSRect(x: screen.minX + 35, y: screen.minY + 45, width: 800, height: 500)
        window.setFrame(expected, display: false)
        first.close()
        let reopened = TerminalWindowController(frameName: name)
        defer {
            first.workspace.stopAll()
            reopened.close()
            window.setFrameAutosaveName("")
            reopened.window?.setFrameAutosaveName("")
            NSWindow.removeFrame(usingName: name)
        }
        let restored = try #require(reopened.window).frame
        #expect(abs(restored.minX - expected.minX) < 2)
        #expect(abs(restored.minY - expected.minY) < 2)
        #expect(abs(restored.width - expected.width) < 2)
        #expect(abs(restored.height - expected.height) < 2)
        #expect(!reopened.shouldCascadeWindows)
    }

    @Test func restoredWindowFitsTerminalGridBeforeAnyManualResize() async throws {
        let name = "SparkGridTest-" + UUID().uuidString
        let first = TerminalWindowController(frameName: name)
        let saved = try #require(first.window)
        saved.setFrame(NSRect(x: 30, y: 30, width: 1400, height: 900), display: false)
        first.close()
        let reopened = TerminalWindowController(frameName: name)
        let window = try #require(reopened.window)
        let session = try #require(reopened.workspace.selected)
        defer {
            reopened.workspace.stopAll()
            reopened.close()
            saved.setFrameAutosaveName("")
            window.setFrameAutosaveName("")
            NSWindow.removeFrame(usingName: name)
        }
        reopened.showWindow(nil)
        try await wait { session.terminal.process.running }
        try await Task.sleep(for: .milliseconds(500))
        let terminal = session.terminal
        let host = try #require(terminal.superview)
        let grid = terminal.getOptimalFrameSize().size
        #expect(abs(terminal.frame.width - host.bounds.width) < 1)
        #expect(abs(terminal.frame.height - host.bounds.height) < 1)
        #expect(abs(grid.width - terminal.bounds.width) < 20)
        #expect(abs(grid.height - terminal.bounds.height) < 30)
    }

    @Test func backingScaleChangeDoesNotReapplyAnOlderGridAfterLayout() async throws {
        let window = ScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let session = TerminalSession(shell: "/bin/sh")
        defer { session.stop(); window.close() }
        window.contentView = session.terminal
        session.start()
        window.orderBack(nil)
        // Moving to a Retina screen queues a resize. Restoring a larger
        // frame before the next Metal frame must supersede that old grid.
        window.testScale = 2
        session.terminal.viewDidChangeBackingProperties()
        window.setContentSize(NSSize(width: 1400, height: 900))
        try await Task.sleep(for: .milliseconds(500))
        let terminal = session.terminal
        let grid = terminal.getOptimalFrameSize().size
        #expect(abs(grid.width - terminal.bounds.width) < 20)
        #expect(abs(grid.height - terminal.bounds.height) < 30)
        let dimensions = terminal.terminalDimensions
        terminal.send(data: Array("printf 'PTY_SIZE:'; stty size\n".utf8)[...])
        try await wait { output(session).contains("PTY_SIZE:\(dimensions.rows) \(dimensions.cols)") }
        #expect(session.dimensions == "\(dimensions.cols) × \(dimensions.rows)")
    }

    private class ScaleWindow: NSWindow {
        var testScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { testScale }
    }

    private func output(_ session: TerminalSession) -> String {
        String(decoding: session.terminal.getBufferAsData(), as: UTF8.self)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Expected terminal event within six seconds")
    }
}
