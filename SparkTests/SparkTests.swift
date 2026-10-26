import AppKit
import Testing
@testable import Spark

@MainActor
struct SparkTests {
    @Test func switchingTabsPreservesSessionsAndClosingSelectsNeighbor() {
        let workspace = Workspace()
        let first = workspace.add()
        let second = workspace.add()
        let originalView = first.terminal
        workspace.selectNext(-1)
        #expect(workspace.selected === first)
        #expect(workspace.selected?.terminal === originalView)
        workspace.remove(first)
        #expect(workspace.selected === second)
        workspace.remove(second)
        #expect(workspace.selected == nil)
        #expect(workspace.sessions.isEmpty)
    }

    @Test func newTabInheritsDirectoryWithoutChangingParentProcess() {
        let workspace = Workspace()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        workspace.add(directory: folder)
        let second = workspace.add()
        #expect(second.directory == folder)
        #expect(second.status == .ready)
        workspace.stopAll()
    }

    @Test func shellEnvironmentPreservesUserToolsAndOverridesTerminalIdentity() {
        let result = TerminalSession.environment(inherited: ["PATH": "/opt/homebrew/bin:/usr/bin", "TERM": "dumb", "LANG": "pt_BR.UTF-8"])
        #expect(result.contains("PATH=/opt/homebrew/bin:/usr/bin"))
        #expect(result.contains("LANG=pt_BR.UTF-8"))
        #expect(result.contains("TERM=xterm-256color"))
        #expect(result.contains("COLORTERM=truecolor"))
        #expect(!result.contains("TERM=dumb"))
    }

    @Test func realPTYExecutesCommandResizesAndTerminates() async throws {
        let session = TerminalSession(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        defer { session.stop() }
        // Keep this proof independent of the user's shell startup files.
        session.terminal.startProcess(executable: "/bin/sh", args: ["-c", "printf '\\033]2;PTY proof\\007'; printf 'SPARK_PTY_OK'; sleep 0.2; exit 7"],
                                      environment: TerminalSession.environment(), currentDirectory: session.directory.path)
        for _ in 0..<100 {
            if case .exited = session.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.status == .exited(7))
        #expect(session.title == "PTY proof")
        #expect(String(decoding: session.terminal.getBufferAsData(), as: UTF8.self).contains("SPARK_PTY_OK"))
        #expect(!session.terminal.process.running)
        #expect(session.terminal.terminalDimensions.cols > 0)
    }

    @Test func closingRunningSessionReleasesProcess() async throws {
        var session: TerminalSession? = TerminalSession()
        weak var view = session?.terminal
        session?.terminal.startProcess(executable: "/bin/sleep", args: ["30"])
        let pid = try #require(session?.terminal.process.shellPid)
        #expect(pid > 0)
        session?.stop()
        session = nil
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(view == nil)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
