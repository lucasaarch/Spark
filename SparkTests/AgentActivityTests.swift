import AppKit
import SwiftTerm
import Testing
@testable import Spark

@MainActor
struct AgentActivityTests {
    @Test func workingOrbMovesAndKeepsFramesWithinItsBounds() {
        let first = WorkingOrbGeometry.frame(at: 0)
        #expect(first != WorkingOrbGeometry.frame(at: 1))
        #expect(first == WorkingOrbGeometry.frame(at: 0))
        for time in [0.0, 0.6, 1, 10, 1_000_000] {
            for dot in WorkingOrbGeometry.frame(at: time) {
                #expect(dot.x.isFinite && dot.y.isFinite && dot.radius.isFinite)
                #expect(dot.x - dot.radius >= 0 && dot.x + dot.radius <= 20)
                #expect(dot.y - dot.radius >= 0 && dot.y + dot.radius <= 20)
                #expect((0...1).contains(dot.opacity))
            }
        }
    }

    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func report(_ body: String) -> String { "\u{1b}]7501;\(body)\u{1b}\\" }

    @Test func detectsOnlyReportedAgentsAndSurfacesChildAttention() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "codex is working\u{1b}]2;Claude Code\u{7}")
        #expect(AgentActivity(records: terminal.programStatusRecords) == nil)
        terminal.feed(text: report("state=working:app=cargo"))
        #expect(AgentActivity(records: terminal.programStatusRecords) == nil)
        terminal.feed(text: report("state=working:app=codex"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.provider == .codex)
        terminal.feed(text: report("state=blocked:id=reviewer:kind=permission"))
        let blocked = try #require(AgentActivity(records: terminal.programStatusRecords))
        #expect(blocked.label == "Needs approval")
        terminal.feed(text: report("state=clear:id=reviewer"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.state == .working)
        terminal.feed(text: report("state=done:app=codex"))
        terminal.feed(text: report("state=clear"))
        #expect(AgentActivity(records: terminal.programStatusRecords) == nil)
        terminal.feed(text: report("state=working:id=orphan:app=codex"))
        #expect(AgentActivity(records: terminal.programStatusRecords) == nil)
    }

    @Test func claudeStatesAreSpecificAndTextIsSanitized() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let text = Data("Review \u{202e}file\u{200b}".utf8).base64EncodedString()
        terminal.feed(text: report("state=blocked:app=claude:kind=question:title=\(text):progress=42"))
        let question = try #require(AgentActivity(records: terminal.programStatusRecords))
        #expect(question.provider == .claude)
        #expect(question.label == "Needs an answer")
        #expect(question.title == "Review file")
        #expect(question.progress == 42)
        terminal.feed(text: report("state=blocked:app=claude-code:kind=auth"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.label == "Sign-in required")
        terminal.feed(text: report("state=error:app=claude-code"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.label == "Error")
        terminal.feed(text: report("state=idle:app=claude-code"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.label == "Ready")
    }

    @Test func reportsStayWithTheirTabAndProcessExitRemovesCompletedAgent() async throws {
        let workspace = Workspace()
        let codex = workspace.add()
        let claude = workspace.add()
        defer { workspace.stopAll() }
        for (session, app, state) in [(codex, "codex", "working"), (claude, "claude", "blocked")] {
            session.terminal.startProcess(
                executable: "/bin/sh",
                args: ["-c", "printf '\\033]7501;state=\(state):app=\(app)\\007'; exec /bin/cat"],
                environment: TerminalSession.environment())
        }
        try await wait { codex.agent != nil && claude.agent != nil }
        workspace.select(codex)
        #expect(codex.agent?.state == .working)
        #expect(claude.agent?.state == .blocked)
        #expect(claude.agent?.provider == .claude)
        workspace.select(claude)
        #expect(codex.agent?.provider == .codex)
        // Completed records are retained by SwiftTerm after exit; Spark must
        // nevertheless remove the agent UI when the owning PTY has ended.
        codex.terminal.feed(text: report("state=done:app=codex"))
        try await wait { codex.agent?.state == .done }
        kill(codex.terminal.process.shellPid, SIGTERM)
        try await wait {
            if case .exited = codex.status { return true }; return false
        }
        #expect(codex.agent == nil)
        #expect(claude.agent?.state == .blocked)
        workspace.remove(claude)
        #expect(claude.agent == nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Expected terminal event within five seconds")
    }
}
