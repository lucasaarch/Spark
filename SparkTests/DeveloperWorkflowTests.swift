import AppKit
import Testing
@testable import Spark

struct GitWorkflowTests {
    @Test func worktreeIsolatesDirtyFilesAndReviewIncludesCommitsAndUntrackedFiles() throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        try "original dirty\n".write(
            to: fixture.repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let tree = try GitRepository.createWorktree(at: fixture.repository.path, branch: "feature/agent")
        #expect(tree.isValid)
        #expect(try String(contentsOfFile: tree.path + "/tracked.txt", encoding: .utf8) == "initial\n")
        #expect(
            try GitRepository.worktrees(at: fixture.repository.path).contains {
                $0.path == tree.path && $0.branch == "feature/agent"
            })
        try "agent commit\n".write(toFile: tree.path + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = try GitRepository.run(at: tree.path, ["add", "tracked.txt"])
        _ = try GitRepository.run(at: tree.path, ["commit", "-m", "Agent change"])
        try "staged content\n".write(toFile: tree.path + "/staged.txt", atomically: true, encoding: .utf8)
        _ = try GitRepository.run(at: tree.path, ["add", "staged.txt"])
        let weirdName = "new [file]\twith spaces.txt"
        try "untracked content\n".write(toFile: tree.path + "/" + weirdName, atomically: true, encoding: .utf8)
        let review = try GitRepository.review(at: tree.path, worktree: tree)
        #expect(review.changes.count == 3)
        let committed = try #require(review.changes.first { $0.path == "tracked.txt" })
        #expect(try GitRepository.diff(committed, review: review).contains("+agent commit"))
        let untracked = try #require(review.changes.first { $0.path == weirdName })
        #expect(try GitRepository.diff(untracked, review: review).contains("+untracked content"))
        #expect(
            try String(contentsOf: fixture.repository.appendingPathComponent("tracked.txt"), encoding: .utf8)
                == "original dirty\n")
        #expect(throws: GitFailure.self) {
            try GitRepository.createWorktree(at: fixture.repository.path, branch: "feature/agent")
        }
        #expect(throws: GitFailure.self) {
            try GitRepository.createWorktree(at: fixture.repository.path, branch: "--detach")
        }
        #expect(try String(contentsOfFile: tree.path + "/tracked.txt", encoding: .utf8) == "agent commit\n")
    }

    @Test func unbornRepositoryAndUntrackedSymlinkAreReviewedWithoutReadingTarget() throws {
        let fixture = try RepositoryFixture(commit: false)
        defer { fixture.remove() }
        let secret = fixture.folder.appendingPathComponent("outside.txt")
        try "OUTSIDE_CONTENT".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.repository.path + "/link", withDestinationPath: secret.path)
        _ = try GitRepository.run(at: fixture.repository.path, ["add", "tracked.txt"])
        let review = try GitRepository.review(at: fixture.repository.path, worktree: nil)
        #expect(review.changes.contains { $0.path == "tracked.txt" && $0.status == "A" })
        let link = try #require(review.changes.first { $0.path == "link" })
        let diff = try GitRepository.diff(link, review: review)
        #expect(diff.contains(secret.path))
        #expect(!diff.contains("OUTSIDE_CONTENT"))
    }

    struct RepositoryFixture {
        let folder: URL
        let repository: URL
        init(commit: Bool = true) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SparkWorkflowTest-" + UUID().uuidString)
            repository = folder.appendingPathComponent("project with spaces")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            _ = try GitRepository.run(at: repository.path, ["init", "-b", "main"])
            _ = try GitRepository.run(at: repository.path, ["config", "user.name", "Spark Test"])
            _ = try GitRepository.run(at: repository.path, ["config", "user.email", "spark@example.invalid"])
            _ = try GitRepository.run(at: repository.path, ["config", "commit.gpgsign", "false"])
            try "initial\n".write(
                to: repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            if commit {
                _ = try GitRepository.run(at: repository.path, ["add", "tracked.txt"])
                _ = try GitRepository.run(at: repository.path, ["commit", "-m", "Initial"])
            }
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }
}

@MainActor
struct ConversationWorkflowTests {
    @Test func codexTruncatedIDResolvesOnlyOneExactPrefixAndKeepsAllowance() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = folder.appendingPathComponent("sessions/2026/10/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
        let prefix = String(id.uuidString.lowercased().prefix(29))
        try Data().write(to: sessions.appendingPathComponent("rollout-date-\(id.uuidString.lowercased()).jsonl"))
        let title =
            "codex | \(prefix)... | codex | 5h 90% left | codex | weekly 81% left | codex | GPT-6 | codex | Context 12% used | codex | 200 in | codex | 50 out | codex | Fix login | codex"
        let metrics = try #require(AgentMetrics.codex(title: title))
        #expect(metrics.codexThreadReference == prefix)
        #expect(metrics.limitingUsage?.remainingPercent == 81)
        #expect(metrics.model == "GPT-6")
        #expect(metrics.sessionTitle == "Fix login")
        #expect(CodexConversationLocator.resolve(prefix, home: folder) == id)
        try Data().write(to: sessions.appendingPathComponent("rollout-date-01234567-89ab-cdef-0123-456789abcde0.jsonl"))
        #expect(CodexConversationLocator.resolve(prefix, home: folder) == nil)
        #expect(CodexConversationLocator.prefix(from: "arbitrary-name") == nil)
        let shortTitle = String(title.prefix(150))
        #expect(AgentMetrics.codex(title: shortTitle)?.limitingUsage?.remainingPercent == 81)
        let claude = try AgentMetrics.claude(data: Data("{\"session_id\":\"\(id.uuidString)\"}".utf8))
        #expect(claude.conversationID == id)
    }

    @Test func oldSnapshotsDecodeAndConversationSurvivesClosingItsPane() async throws {
        let workspace = Workspace()
        defer { workspace.stopAll() }
        let session = workspace.add()
        workspace.add()
        let old = try JSONEncoder().encode(workspace.snapshot())
        var legacy = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        legacy.removeValue(forKey: "conversations")
        let decoded = try JSONDecoder().decode(
            WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.isValid)
        #expect(decoded.conversations == nil)
        let reference = AgentConversation(
            id: UUID(), provider: .codex, title: "Fix login", directory: NSHomeDirectory())
        session.conversation = reference
        try await Task.sleep(for: .milliseconds(50))
        workspace.remove(session)
        let snapshot = workspace.snapshot()
        #expect(snapshot.conversations == [reference])
        let restored = Workspace(
            snapshot: try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)))
        defer { restored.stopAll() }
        #expect(restored.conversations == [reference])
        restored.resume(reference)
        #expect(restored.selected?.conversation == reference)
        #expect(restored.selected?.status == .ready)
        #expect(restored.sessions.count == 2)
    }

    @Test(arguments: AgentActivity.Provider.allCases)
    func resumeWaitsForInstantPromptToRestoreTerminal(provider: AgentActivity.Provider) async throws {
        let fixture = try AgentMetricsTests.Fixture()
        defer { fixture.remove() }
        // Reproduce p10k's startup contract and race: restore descriptors after
        // Spark's first scheduled launch attempt.
        let startupFile = fixture.folder.appendingPathComponent(".zshrc")
        let startup =
            try String(contentsOf: startupFile, encoding: .utf8)
                .replacingOccurrences(of: "unsetopt zle\n", with: "") + """

                exec {saved_in}<&0 {saved_out}>&1 {saved_err}>&2
                exec </dev/null >"$HOME/startup-output" 2>&1
                function restore_startup_io {
                  exec 0<&$saved_in 1>&$saved_out 2>&$saved_err
                  exec {saved_in}<&- {saved_out}>&- {saved_err}>&-
                }
                function schedule_startup_io {
                  zmodload zsh/sched
                  sched +1 restore_startup_io
                  precmd_functions=(${precmd_functions:#schedule_startup_io})
                }
                precmd_functions=(schedule_startup_io)
                """
        try startup.write(to: startupFile, atomically: true, encoding: .utf8)
        try "".write(to: fixture.folder.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        let cli = """
            #!/bin/sh
            if [ ! -t 0 ] || [ ! -t 1 ] || [ ! -t 2 ]; then
              printf 'Error: stdin is not a terminal\n'
              exit 1
            fi
            printf 'RESUMED_WITH_TTY:%s|%s\n' "$3" "$4"
            printf '\\033]7501;state=idle:app=\(provider.rawValue)\\007'
            IFS= read -r line
            """
        try cli.write(to: fixture.folder.appendingPathComponent(provider.rawValue), atomically: true, encoding: .utf8)
        let id = UUID()
        let session = TerminalSession(
            directory: fixture.folder, launch: AgentLaunch(provider: provider, conversationID: id))
        defer { session.stop() }
        session.start(environment: fixture.environment(percent: 10))
        // The launcher reports its provider before the CLI writes its output.
        let expectedResume = "RESUMED_WITH_TTY:\(provider == .codex ? "resume" : "--resume")|\(id.uuidString.lowercased())"
        var output = ""
        for _ in 0..<300 {
            output = String(decoding: session.terminal.getBufferAsData(), as: UTF8.self)
            if output.contains(expectedResume) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(output.contains(expectedResume))
        let captured = try String(contentsOf: fixture.folder.appendingPathComponent("startup-output"), encoding: .utf8)
        #expect(captured.isEmpty)
    }

    @Test(arguments: AgentActivity.Provider.allCases)
    func resumeLaunchPassesExactIDOnceWithoutTypingIntoShell(provider: AgentActivity.Provider) async throws {
        let fixture = try AgentMetricsTests.Fixture()
        defer { fixture.remove() }
        let id = UUID()
        let cli = """
            #!/bin/sh
            printf 'RESUME_ARGS:%s|%s\\n' "$3" "$4"
            printf '\\033]7501;state=idle:app=\(provider.rawValue)\\007'
            IFS= read -r line
            """
        try cli.write(to: fixture.folder.appendingPathComponent(provider.rawValue), atomically: false, encoding: .utf8)
        let session = TerminalSession(
            directory: fixture.folder, launch: AgentLaunch(provider: provider, conversationID: id))
        defer { session.stop() }
        session.start(environment: fixture.environment(percent: 10))
        let expectedResume = "RESUME_ARGS:\(provider == .codex ? "resume" : "--resume")|\(id.uuidString.lowercased())"
        var output = ""
        for _ in 0..<150 {
            output = String(decoding: session.terminal.getBufferAsData(), as: UTF8.self)
            if output.contains(expectedResume) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(output.contains(expectedResume))
        session.terminal.send(data: Array("exit\n".utf8)[...])
        for _ in 0..<150 {
            if session.agent == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.agent == nil)
        #expect(session.status == .running)
        session.terminal.send(data: Array("printf 'SHELL_RETURNED\\n'\n".utf8)[...])
        var after = ""
        for _ in 0..<150 {
            after = String(decoding: session.terminal.getBufferAsData(), as: UTF8.self)
            if after.contains("SHELL_RETURNED") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(after.contains("SHELL_RETURNED"))
        #expect(after.components(separatedBy: "RESUME_ARGS:").count == 2)
    }
}
