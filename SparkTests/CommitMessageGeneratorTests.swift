import Foundation
import Testing
@testable import Spark

struct CommitMessageGeneratorTests {
    @Test func cleansOneLineSubjectsAndRejectsPromptEchoes() throws {
        #expect(try CommitMessageGenerator.normalize("  **fix: preserve staged edits**\nExtra text", provider: .codex)
            == "fix: preserve staged edits")
        #expect(throws: GitFailure.self) {
            try CommitMessageGenerator.normalize(
                "Describe the concrete code change shown in the staged diff", provider: .claude)
        }
    }

    @Test func exposesTheCliRuntimeOnPathAndWritesPromptToStandardInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = directory.appending(path: "node")
        let nodeScript = #"""
            #!/bin/sh
            IFS= read -r request
            [ "$request" = 'untrusted staged diff' ] || exit 11
            printf 'fix: stage only intended files\n'
            """#
        try nodeScript.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let cli = directory.appending(path: "mock-codex")
        try "#!/usr/bin/env node\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let response = try await CommitMessageGenerator.run(
            provider: .codex, executable: cli.path, request: "untrusted staged diff")
        #expect(try CommitMessageGenerator.normalize(response, provider: .codex) == "fix: stage only intended files")
    }
}
