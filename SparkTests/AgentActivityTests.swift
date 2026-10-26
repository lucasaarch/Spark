import AppKit
import SwiftTerm
import Testing
@testable import Spark

@MainActor
struct AgentActivityTests {
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
        #expect(!blocked.acceptsCommands)
        terminal.feed(text: report("state=clear:id=reviewer"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.state == .working)
        terminal.feed(text: report("state=done:app=codex"))
        #expect(AgentActivity(records: terminal.programStatusRecords)?.acceptsCommands == true)
        terminal.feed(text: report("state=clear"))
        #expect(AgentActivity(records: terminal.programStatusRecords) == nil)
        terminal.feed(text: report("state=working:id=orphan:app=codex"))
        #expect(AgentActivity(records: terminal.programStatusRecords) == nil)
    }

    @Test func claudeStatesAndCommandsAreProviderSpecificAndTextIsSanitized() throws {
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
        #expect(AgentActivity.Command.context.text(for: .claude) == "/context")
        #expect(AgentActivity.Command.context.text(for: .codex) == "/status")
        for provider in [AgentActivity.Provider.codex, .claude] {
            #expect(AgentActivity.Command.usage.text(for: provider) == "/usage")
            for command in AgentActivity.Command.allCases {
                #expect(!command.text(for: provider).contains(where: { $0.isNewline }))
            }
        }
    }

    @Test func realPTYDeliversStatusAndInsertsCommandWithoutSubmitting() async throws {
        let session = TerminalSession()
        defer { session.stop() }
        // Canonical input must remain pending until Return is explicitly sent.
        let script = #"""
        stty -echo icanon
        printf '\033]7501;state=idle:app=codex\007'
        IFS= read -r command
        printf 'CAPTURED[%s]' "$command"
        printf '\033]7501;state=blocked:app=codex:kind=permission\007'
        sleep 0.5
        printf '\033]7501;state=working:app=codex\007'
        sleep 0.5
        printf '\033]7501;state=done:app=codex\007'
        sleep 0.5
        printf '\033]7501;state=clear\007'
        sleep 0.5
        """#
        session.terminal.startProcess(executable: "/bin/sh", args: ["-c", script], environment: TerminalSession.environment())
        try await wait { session.agent?.state == .idle }
        #expect(session.insertAgentCommand(.context))
        try await Task.sleep(for: .milliseconds(150))
        #expect(session.agent?.state == .idle)
        #expect(!String(decoding: session.terminal.getBufferAsData(), as: UTF8.self).contains("CAPTURED["))
        session.terminal.send(data: [13][...])
        try await wait { session.agent?.kind == .permission }
        #expect(!session.insertAgentCommand(.usage))
        #expect(String(decoding: session.terminal.getBufferAsData(), as: UTF8.self).contains("CAPTURED[/status]"))
        try await wait { session.agent?.state == .working }
        try await wait { session.agent?.state == .done }
        session.showsAgentDetails = true
        try await wait { session.agent == nil }
        #expect(!session.showsAgentDetails)
        #expect(!session.insertAgentCommand(.context))
        try await wait { session.status == .exited(0) }
    }

    @Test func reportsStayWithTheirTabAndProcessExitRemovesCompletedAgent() async throws {
        let workspace = Workspace()
        let codex = workspace.add()
        let claude = workspace.add()
        defer { workspace.stopAll() }
        for (session, app, state) in [(codex, "codex", "working"), (claude, "claude", "blocked")] {
            session.terminal.startProcess(executable: "/bin/sh",
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
        try await wait { if case .exited = codex.status { return true }; return false }
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
