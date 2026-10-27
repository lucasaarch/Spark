import Foundation
import Testing
@testable import Spark

@MainActor
struct RepositoryWatcherTests {
    @Test func watchesNestedAtomicEditsAndLinkedGitMetadataThenStops() async throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let tree = try GitRepository.createWorktree(at: fixture.repository.path, branch: "watch-test")
        let paths = GitRepository.observationDirectories(at: tree.path)
        #expect(paths.contains { $0.hasSuffix("/.git") })
        #expect(paths.contains { $0.contains("/.git/worktrees/") })
        let watcher = try RepositoryWatcher(directories: paths)
        defer { watcher.stop() }
        var events = 0
        let reader = Task { for await _ in watcher.changes { events += 1 } }
        defer { reader.cancel() }
        try await wait { events > 0 }
        let folder = URL(fileURLWithPath: tree.path).appendingPathComponent("Sources/Nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("main.swift")
        var before = events
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try await wait { events > before }
        before = events
        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        try await wait { events > before }
        before = events
        _ = try GitRepository.run(at: tree.path, ["add", "."])
        try await wait { events > before }
        before = events
        _ = try GitRepository.run(at: tree.path, ["commit", "-m", "Observe metadata"])
        try await wait { events > before }
        before = events
        try FileManager.default.removeItem(at: file)
        try await wait { events > before }
        watcher.stop()
        await reader.value
        before = events
        try "let value = 3\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(events == before)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(condition(), "Expected a filesystem event within six seconds")
    }
}
