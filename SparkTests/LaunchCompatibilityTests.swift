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
