import AppKit
import Testing
@testable import Spark

@MainActor
struct AgentMetricsTests {
    private func codexTitle(_ name: String = "") -> String {
        "codex" + (name.isEmpty ? "" : " | \(name)") + " | codex | GPT-6 | codex | Context 37% used | codex | 12.4k in | codex | 620 out | codex | codex | weekly 86% left | codex"
    }

    @Test func codexSlotsPreserveMissingValuesAndDiscardTruncatedFields() throws {
        let value = try #require(AgentMetrics.codex(title: codexTitle()))
        #expect(value.model == "GPT-6")
        #expect(value.contextPercent == 37)
        #expect(value.inputTokens == "12.4k")
        #expect(value.outputTokens == "620")
        #expect(value.sessionTitle == nil)
        #expect(value.limits.count == 1)
        #expect(value.limits.first?.name == "Weekly limit")
        #expect(value.limits.first?.detail == "weekly 86% left")
        #expect(AgentMetrics.codex(title: codexTitle("Fix payments"))?.sessionTitle == "Fix payments")
        let truncated = try #require(AgentMetrics.codex(title: String(codexTitle("Fix payments").dropLast(5))))
        #expect(truncated.sessionTitle == "Fix payments")
        #expect(truncated.limits.isEmpty)
        #expect(AgentMetrics.codex(title: "codex | unrelated title") == nil)
    }

    @Test func claudeReportsContextCostAndLimitsWithoutRetainingConversationData() throws {
        let payload = #"{"model":{"display_name":"Opus"},"session_name":"Fix login","context_window":{"used_percentage":42.5,"context_window_size":200000,"total_input_tokens":84000,"total_output_tokens":1000},"cost":{"total_cost_usd":1.2345},"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":2000000000}},"transcript_path":"/private/conversation.jsonl","prompt":"PRIVATE_CONTENT"}"#
        let value = try AgentMetrics.claude(data: Data(payload.utf8))
        #expect(value.model == "Opus")
        #expect(value.contextPercent == 42.5)
        #expect(value.inputTokens == "84000")
        #expect(value.costUSD == 1.2345)
        #expect(value.limits.first?.usedPercent == 25)
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE_CONTENT"))
        #expect(!encoded.contains("transcript"))
        let missing = try AgentMetrics.claude(data: Data("{}".utf8))
        #expect(missing.contextPercent == nil)
        #expect(missing.inputTokens == nil)
        let invalid = try AgentMetrics.claude(data: Data(#"{"context_window":{"used_percentage":101,"total_input_tokens":-1},"cost":{"total_cost_usd":-3}}"#.utf8))
        #expect(invalid.contextPercent == nil)
        #expect(invalid.inputTokens == nil)
        #expect(invalid.costUSD == nil)
    }

    @Test func orderedPTYMetricsUseCodexUntilARealTitleArrivesAndClearOnExit() async throws {
        let session = TerminalSession()
        defer { session.stop() }
        session.terminal.startProcess(executable: "/bin/cat")
        // All events deliberately arrive in one chunk: coalesced title
        // callbacks must not lose the integration marker or empty-name state.
        session.terminal.feed(text: "\u{1b}]9001;SparkAgent:codex\u{7}\u{1b}]7501;state=idle:app=codex\u{7}\u{1b}]0;\(codexTitle())\u{7}")
        try await wait { session.metrics?.contextPercent == 37 }
        #expect(session.title == "Codex")
        session.terminal.feed(text: "\u{1b}]0;\(codexTitle("Fix login"))\u{7}")
        try await wait { session.title == "Fix login" }
        session.terminal.feed(text: "\u{1b}]9001;SparkAgent:end\u{7}\u{1b}]7501;state=clear\u{7}")
        try await wait { session.metrics == nil && session.agent == nil }
    }

    @Test func zshStartupAndClaudeBridgeStayIsolatedAcrossTwoTabs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = TerminalSession(directory: fixture.folder, shell: "/bin/zsh")
        let second = TerminalSession(directory: fixture.folder, shell: "/bin/zsh")
        defer { first.stop(); second.stop() }
        first.start(environment: fixture.environment(percent: 23))
        second.start(environment: fixture.environment(percent: 71))
        try await wait { output(first).contains("STARTUP_READY") && output(second).contains("STARTUP_READY") }
        for session in [first, second] { session.terminal.send(data: Array("claude\n".utf8)[...]) }
        try await wait { first.metrics?.contextPercent == 23 && second.metrics?.contextPercent == 71 }
        #expect(first.agent?.provider == .claude)
        #expect(second.agent?.provider == .claude)
        #expect(first.metrics?.model == "Fixture Opus")
        #expect(first.metrics?.costUSD == 0.125)
        #expect(first.metrics?.limits.first?.usedPercent == 30)
        #expect(first.title == "Claude Code")
        first.terminal.send(data: Array("exit\n".utf8)[...])
        try await wait { first.metrics == nil && first.agent == nil }
        #expect(second.metrics?.contextPercent == 71)
        // A new invocation gets another UUID; the old file must never surface.
        first.terminal.send(data: Array("export SPARK_TEST_PERCENT=48; claude\n".utf8)[...])
        try await wait { first.metrics?.contextPercent == 48 }
        #expect(second.metrics?.contextPercent == 71)
    }

    @Test func shellIntegrationPreservesUserStartupAndAutomation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = TerminalSession(directory: fixture.folder, shell: "/bin/zsh")
        defer { session.stop() }
        session.start(environment: fixture.environment(percent: 10))
        try await wait { output(session).contains("STARTUP_READY") }
        session.terminal.send(data: Array("printf 'ORDER:%s\\n' \"$SPARK_STARTUP_ORDER\"; [[ $ZDOTDIR == $SPARK_TEST_BIN ]] && printf 'ZDOTDIR_RESTORED\\n'; codex </dev/null\n".utf8)[...])
        try await wait { output(session).contains("AUTOMATION_UNCHANGED") }
        #expect(output(session).contains("ORDER:env,profile,rc,login,"))
        #expect(output(session).contains("ZDOTDIR_RESTORED"))
        #expect(session.metrics == nil)
        session.terminal.send(data: Array("codex\n".utf8)[...])
        try await wait { session.metrics?.contextPercent == 37 }
        #expect(session.title == "Codex")
    }

    private func output(_ session: TerminalSession) -> String {
        String(decoding: session.terminal.getBufferAsData(), as: UTF8.self)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Expected metric event within six seconds")
    }

    struct Fixture {
        let folder: URL
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("Spark-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for (name, marker) in [(".zshenv", "env"), (".zprofile", "profile"), (".zshrc", "rc"), (".zlogin", "login")] {
                var script = "export SPARK_STARTUP_ORDER=\"${SPARK_STARTUP_ORDER}\(marker),\"\n"
                if name == ".zshrc" { script += "export PATH=\"$SPARK_TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin\"\nPROMPT=''\nunsetopt zle\nstty -echo\n" }
                if name == ".zlogin" { script += "printf 'STARTUP_READY\\n'\n" }
                try script.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let claude = #"""
            #!/bin/sh
            test "$1" = --settings || exit 9
            printf '\033]7501;state=idle:app=claude\007'
            printf '{"model":{"display_name":"Fixture Opus"},"context_window":{"used_percentage":%s,"context_window_size":200000,"total_input_tokens":46000,"total_output_tokens":500},"cost":{"total_cost_usd":0.125},"rate_limits":{"five_hour":{"used_percentage":30}}}' "$SPARK_TEST_PERCENT" | "$SPARK_EXECUTABLE" --claude-status
            IFS= read -r line
            """#
            let codex = #"""
            #!/bin/sh
            if [ ! -t 0 ]; then printf 'AUTOMATION_UNCHANGED\n'; exit; fi
            test "$1" = -c || exit 9
            printf '\033]7501;state=idle:app=codex\007\033]0;codex | codex | Fixture GPT | codex | Context 37%% used | codex | 100 in | codex | 10 out | codex | codex | codex\007'
            IFS= read -r line
            """#
            for (name, content) in [("claude", claude), ("codex", codex)] {
                let file = folder.appendingPathComponent(name)
                try content.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
        }

        func environment(percent: Int) -> [String: String] {
            ["HOME": folder.path, "ZDOTDIR": folder.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
             "SPARK_TEST_BIN": folder.path, "SPARK_TEST_PERCENT": String(percent)]
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }
}
