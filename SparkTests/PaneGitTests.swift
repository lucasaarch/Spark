import AppKit
import Testing
@testable import Spark

struct GitMutationTests {
    @Test func sourceControlKeepsIndexAndWorkingTreeStatusesSeparate() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let root = fixture.repository.path
        try "staged edit\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        try GitRepository.stage("tracked.txt", at: root)
        try "working edit\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        try "new file\n".write(toFile: root + "/added.txt", atomically: true, encoding: .utf8)
        try GitRepository.stage("added.txt", at: root)
        try "untracked\n".write(toFile: root + "/untracked.txt", atomically: true, encoding: .utf8)

        let snapshot = try GitRepository.sourceControl(at: root)
        let tracked = try #require(snapshot.files.first { $0.path == "tracked.txt" })
        let added = try #require(snapshot.files.first { $0.path == "added.txt" })
        let untracked = try #require(snapshot.files.first { $0.path == "untracked.txt" })
        #expect(tracked.statusLetter(isStaged: true) == "M")
        #expect(tracked.statusLetter(isStaged: false) == "M")
        #expect(added.statusLetter(isStaged: true) == "A")
        #expect(untracked.statusLetter(isStaged: false) == "U")
    }

    @Test func stagingAndCommitPreserveUnstagedWorkAndRejectChangedIndex() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let root = fixture.repository.path
        let tracked = URL(fileURLWithPath: root).appendingPathComponent("tracked.txt")
        try "staged version\n".write(to: tracked, atomically: true, encoding: .utf8)
        try GitRepository.stage("tracked.txt", at: root)
        let expected = try GitRepository.sourceControl(at: root)
        #expect(expected.stagedFiles.map(\.path) == ["tracked.txt"])
        #expect(expected.unstagedFiles.isEmpty)

        try "later working edit\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "new file\n".write(
            to: URL(fileURLWithPath: root).appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try GitRepository.commit(at: root, message: "Keep only staged content", expected: expected)

        #expect(try String(contentsOf: tracked, encoding: .utf8) == "later working edit\n")
        #expect(try GitRepository.run(at: root, ["show", "HEAD:tracked.txt"]) == "staged version\n")
        let remaining = try GitRepository.sourceControl(at: root)
        #expect(remaining.stagedFiles.isEmpty)
        #expect(remaining.unstagedFiles.map(\.path).sorted() == ["new.txt", "tracked.txt"])

        try GitRepository.stage("new.txt", at: root)
        let stale = try GitRepository.sourceControl(at: root)
        try GitRepository.stage("tracked.txt", at: root)
        #expect(throws: GitFailure.self) {
            try GitRepository.commit(at: root, message: "Reject stale index", expected: stale)
        }
        try GitRepository.unstage("new.txt", at: root)
        #expect(FileManager.default.fileExists(atPath: root + "/new.txt"))
        #expect(try GitRepository.sourceControl(at: root).stagedFiles.map(\.path) == ["tracked.txt"])
    }

    @Test func namesHaveTwoWordsAndCreationPinsTheSourceBranch() throws {
        for _ in 0..<40 {
            let name = GitRepository.suggestedName()
            #expect(name.split(separator: "-").count == 2)
            #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") })
        }
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let source = try GitRepository.inspect(at: fixture.repository.path)
        _ = try GitRepository.run(at: source.root, ["switch", "-c", "another-branch"])
        #expect(throws: GitFailure.self) {
            try GitRepository.createWorktree(at: source.root, branch: "amber-fox", expected: source)
        }
        let tree = try GitRepository.createWorktree(at: source.root, branch: "silver-otter")
        #expect(URL(fileURLWithPath: tree.path).lastPathComponent == "silver-otter")
        #expect(tree.baseBranch == "another-branch")
    }

    @Test func mergeUsesOriginalBranchAndPreservesBothWorkingTrees() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let main = fixture.repository.path
        let tree = try GitRepository.createWorktree(at: main, branch: "calm-owl")
        try "agent change\n".write(toFile: tree.path + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = try GitRepository.run(at: tree.path, ["add", "."])
        _ = try GitRepository.run(at: tree.path, ["commit", "-m", "Agent change"])
        try "main-only\n".write(toFile: main + "/other.txt", atomically: true, encoding: .utf8)
        let source = try GitRepository.inspect(at: tree.path)
        #expect(throws: GitFailure.self) { try GitRepository.prepareMerge(source: source, record: tree) }
        _ = try GitRepository.run(at: main, ["add", "."])
        _ = try GitRepository.run(at: main, ["commit", "-m", "Parallel main change"])
        let plan = try GitRepository.prepareMerge(source: source, record: tree)
        #expect(plan.destination.branch == "main")
        try GitRepository.merge(plan)
        #expect(try String(contentsOfFile: main + "/tracked.txt", encoding: .utf8) == "agent change\n")
        #expect(try String(contentsOfFile: main + "/other.txt", encoding: .utf8) == "main-only\n")
        #expect(try GitRepository.inspect(at: tree.path).branch == "calm-owl")
        #expect(try GitRepository.run(at: main, ["status", "--porcelain"]).isEmpty)
        #expect(throws: GitFailure.self) { try GitRepository.merge(plan) }
    }

    @Test func conflictingMergeLeavesDestinationUntouched() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let main = fixture.repository.path
        let tree = try GitRepository.createWorktree(at: main, branch: "bright-fern")
        for (path, text) in [(main, "main edit"), (tree.path, "agent edit")] {
            try text.write(toFile: path + "/tracked.txt", atomically: true, encoding: .utf8)
            _ = try GitRepository.run(at: path, ["add", "."])
            _ = try GitRepository.run(at: path, ["commit", "-m", text])
        }
        let plan = try GitRepository.prepareMerge(source: GitRepository.inspect(at: tree.path), record: tree)
        #expect(throws: GitFailure.self) { try GitRepository.merge(plan) }
        #expect(try String(contentsOfFile: main + "/tracked.txt", encoding: .utf8) == "main edit")
        #expect(try GitRepository.run(at: main, ["status", "--porcelain"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: main + "/.git/MERGE_HEAD"))
    }

    @Test func discardChecksForNewEditsAndKeepsRecoveryCopies() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let root = fixture.repository.path
        try "staged\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = try GitRepository.run(at: root, ["add", "."])
        try "unstaged\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        try "new file\n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
        let review = try GitRepository.review(at: root, worktree: nil)
        let stale = try GitRepository.prepareDiscard(review: review, changes: review.changes)
        try "edit after dialog\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        #expect(throws: GitFailure.self) { try GitRepository.discard(stale) }
        #expect(try String(contentsOfFile: root + "/tracked.txt", encoding: .utf8) == "edit after dialog\n")
        let plan = try GitRepository.prepareDiscard(review: review, changes: review.changes)
        let backup = try GitRepository.discard(plan)
        #expect(try String(contentsOfFile: root + "/tracked.txt", encoding: .utf8) == "initial\n")
        #expect(!FileManager.default.fileExists(atPath: root + "/new.txt"))
        #expect(
            try String(contentsOf: backup.appendingPathComponent("files/tracked.txt"), encoding: .utf8)
                == "edit after dialog\n")
        #expect(try String(contentsOf: backup.appendingPathComponent("files/new.txt"), encoding: .utf8) == "new file\n")
        #expect(
            try String(contentsOf: backup.appendingPathComponent("staged.patch"), encoding: .utf8).contains("+staged"))
        #expect(
            try String(contentsOf: backup.appendingPathComponent("working.patch"), encoding: .utf8).contains(
                "+edit after dialog"))
        #expect(try GitRepository.run(at: root, ["status", "--porcelain"]).isEmpty)
    }

    @Test func indexOnlyChangesRemainVisibleAndUnbornDiscardsWork() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let root = fixture.repository.path
        try "staged edit\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = try GitRepository.run(at: root, ["add", "."])
        try "initial\n".write(toFile: root + "/tracked.txt", atomically: true, encoding: .utf8)
        let review = try GitRepository.review(at: root, worktree: nil)
        #expect(review.changes.map(\.path) == ["tracked.txt"])
        _ = try GitRepository.discard(GitRepository.prepareDiscard(review: review, changes: review.changes))
        #expect(try GitRepository.run(at: root, ["status", "--porcelain"]).isEmpty)
        let unborn = try GitWorkflowTests.RepositoryFixture(commit: false)
        defer { unborn.remove() }
        _ = try GitRepository.run(at: unborn.repository.path, ["add", "."])
        let initial = try GitRepository.review(at: unborn.repository.path, worktree: nil)
        _ = try GitRepository.discard(GitRepository.prepareDiscard(review: initial, changes: initial.changes))
        #expect(try GitRepository.run(at: unborn.repository.path, ["status", "--porcelain"]).isEmpty)
    }

    @Test func nonRepositoryProducesAnActionableError() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        do {
            _ = try GitRepository.review(at: fixture.folder.path, worktree: nil)
            Issue.record("Expected non-repository error")
        } catch let error as GitFailure {
            #expect(error.isNotRepository)
            #expect(!error.message.contains("fatal:"))
        }
    }

    @Test func discardingSymlinkAndBinaryKeepsTheirRecoveryDataAndOutsideTarget() throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let root = fixture.repository.path
        let outside = fixture.folder.appendingPathComponent("outside.txt")
        try "preserve outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside.path)
        let binary = Data([0, 255, 1, 254, 0])
        try binary.write(to: fixture.repository.appendingPathComponent("new.bin"))
        let review = try GitRepository.review(at: root, worktree: nil)
        let backup = try GitRepository.discard(GitRepository.prepareDiscard(review: review, changes: review.changes))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve outside")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: backup.appendingPathComponent("files/link").path)
                == outside.path)
        #expect(try Data(contentsOf: backup.appendingPathComponent("files/new.bin")) == binary)
        #expect(try GitRepository.run(at: root, ["status", "--porcelain"]).isEmpty)
    }
}

@MainActor
struct PaneGitTests {
    @Test func reviewAndCreationCaptureTheExplicitTerminalAcrossAsyncProbes() async throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let workspace = Workspace()
        defer { workspace.stopAll() }
        let source = workspace.add(directory: fixture.repository)
        let other = workspace.add(directory: fixture.folder)
        workspace.showReview(for: source)
        workspace.showWorktreeCreator(for: source)
        for _ in 0..<100 {
            if workspace.reviewSession != nil && workspace.worktreeSession != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.selected === other)
        #expect(workspace.reviewSession === source)
        #expect(workspace.worktreeSession === source)
        #expect(source.repository?.branch == "main")
    }
    @Test func cwdComesFromTheShellEvenWithoutPromptIntegration() async throws {
        let shell = try AgentMetricsTests.Fixture()
        let git = try GitWorkflowTests.RepositoryFixture()
        defer { shell.remove(); git.remove() }
        let session = TerminalSession(directory: shell.folder, shell: "/bin/zsh")
        defer { session.stop() }
        session.start(environment: shell.environment(percent: 10))
        try await Task.sleep(for: .milliseconds(150))
        session.terminal.send(data: Array("cd '\(git.repository.path)'\n".utf8)[...])
        for _ in 0..<50 {
            await session.refreshRepository()
            if session.repository != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.repository?.branch == "main")
        #expect(session.directory.resolvingSymlinksInPath() == git.repository.resolvingSymlinksInPath())
        session.terminal.send(data: Array("cd '\(shell.folder.path)'\n".utf8)[...])
        for _ in 0..<50 {
            await session.refreshRepository()
            if session.repository == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.repository == nil)
    }

    @Test func explicitSourceSplitsTheCorrectTabRegardlessOfFocus() throws {
        let workspace = Workspace()
        defer { workspace.stopAll() }
        let origin = workspace.add(directory: URL(fileURLWithPath: "/tmp"))
        let other = workspace.add(directory: URL(fileURLWithPath: "/Users"))
        let sourceTab = try #require(workspace.tabs.first)
        let split = try #require(
            workspace.split(.vertical, source: origin, directory: URL(fileURLWithPath: "/private/tmp")))
        #expect(workspace.tabs.first?.id == sourceTab.id)
        #expect(workspace.tabs.first?.layout.sessionIDs == [origin.id, split.id])
        #expect(workspace.tabs.last?.layout.sessionIDs == [other.id])
        #expect(workspace.selected === split)
    }

    @Test func codeReviewUsesLineNumbersSyntaxColorsAndNoPatchHeaders() async throws {
        let patch =
            """
            diff --git a/test.swift b/test.swift\n--- a/test.swift\n+++ b/test.swift\n@@ -1,2 +1,2 @@\n-let name = \"old\"\n+let name = \"new\"\n print(name)\n@@ -10 +10 @@\n-return false\n+return true\n
            """
        let rendered = await ReviewRenderer.shared.render(
            patch: patch, path: "test.swift", old: "let name = \"old\"\nprint(name)\n",
            new: "let name = \"new\"\nprint(name)\n")
        #expect(rendered.document.lines.first?.oldNumber == 1)
        #expect(rendered.document.lines[1].newNumber == 1)
        #expect(rendered.document.lines.last?.newNumber == 10)
        #expect(rendered.document.additions == 2 && rendered.document.deletions == 2)
        #expect(!rendered.text.string.contains("diff --git"))
        #expect(!rendered.text.string.contains("+let"))
        #expect(rendered.text.string.contains("let name = \"new\""))
        var colors = Set<String>()
        let fullRange = NSRange(location: 0, length: rendered.text.length)
        rendered.text.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color.description) }
        }
        #expect(colors.count >= 3)
        let nodes = ReviewFileNode.tree([
            .init(path: "Sources/App/Main.swift", status: "M"), .init(path: "Sources/App/UI.swift", status: "A"),
            .init(path: "README.md", status: "M")
        ])
        #expect(nodes.first?.name == "Sources")
        #expect(nodes.first?.children?.first?.children?.count == 2)
    }
}
