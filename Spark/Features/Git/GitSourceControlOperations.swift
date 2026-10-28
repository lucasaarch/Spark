import Foundation
import CryptoKit

extension GitRepository {
    static func review(at directory: String, worktree: WorktreeRecord?) throws -> GitReview {
        let root = try root(at: directory)
        let matchesWorktree =
            worktree.map {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            } ?? false
        let base: String
        if matchesWorktree, let worktree {
            base = try run(at: root, ["rev-parse", "--verify", worktree.baseCommit + "^{commit}"]).trimmingCharacters(
                in: .newlines)
        } else if let head = try? run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]) {
            base = head.trimmingCharacters(in: .newlines)
        } else {
            // Git recognizes the empty tree, including in an unborn repository.
            base = try run(at: root, ["hash-object", "-t", "tree", "/dev/null"]).trimmingCharacters(in: .newlines)
        }
        let branch =
            (try? run(at: root, ["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines))
            ?? "Detached HEAD"
        let fields = try run(
            at: root, ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", base, "--"]
        )
        .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [GitChange] = []
        for index in stride(from: 0, to: fields.count - fields.count % 2, by: 2) {
            changes.append(GitChange(path: fields[index + 1], status: fields[index]))
        }
        if worktree == nil {
            // An unstaged edit can cancel a staged edit in the final file.
            // Keep that file reviewable/discardable even when diff HEAD is empty.
            let staged = try run(
                at: root,
                [
                    "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", base,
                    "--"
                ]
            )
            .split(separator: "\0").map(String.init)
            for index in stride(from: 0, to: staged.count - staged.count % 2, by: 2)
            where !changes.contains(where: { $0.path == staged[index + 1] }) {
                changes.append(GitChange(path: staged[index + 1], status: staged[index]))
            }
        }
        let untracked = try run(at: root, ["ls-files", "--others", "--exclude-standard", "-z"])
        let untrackedChanges = untracked.split(separator: "\0").map { GitChange(path: String($0), status: "?") }
        changes += untrackedChanges.filter { candidate in
            !changes.contains { $0.path == candidate.path }
        }
        return GitReview(root: root, base: base, branch: branch, changes: changes.sorted { $0.path < $1.path })
    }

    static func sourceControl(at directory: String) throws -> GitSourceSnapshot {
        let root = try root(at: directory)
        let branch =
            (try? run(at: root, ["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines))
            ?? "Detached HEAD"
        let head = try? run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .newlines)
        let status = try run(at: root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"])
        let conflicts: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        let files = status.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry -> GitSourceFile? in
            let fields = Array(entry)
            guard fields.count >= 4, fields[2] == " " else { return nil }
            let index = fields[0], worktree = fields[1]
            let path = String(fields.dropFirst(3))
            let isUntracked = index == "?" && worktree == "?"
            return GitSourceFile(
                path: path,
                isStaged: index != " " && index != "?",
                isUnstaged: worktree != " " || isUntracked,
                isUntracked: isUntracked,
                isConflicted: conflicts.contains(String([index, worktree])),
                indexStatus: String(index), worktreeStatus: String(worktree))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let index = try run(at: root, ["ls-files", "--stage", "-z"])
        let upstream = try? run(at: root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let counts =
            upstream?.isEmpty == false
            ? ((try? run(at: root, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]))?
                .split(whereSeparator: \.isWhitespace) ?? []) : []
        let ahead = counts.count == 2 ? Int(counts[0]) ?? 0 : 0
        let behind = counts.count == 2 ? Int(counts[1]) ?? 0 : 0
        let remotes = (try? run(at: root, ["remote"]).split(whereSeparator: \.isNewline).map(String.init)) ?? []
        let stashOutput = try? run(at: root, ["stash", "list", "--format=%H%x00%gs"])
        let stashes =
            stashOutput?.components(separatedBy: .newlines).compactMap { line -> GitStash? in
                let fields = line.split(separator: "\0", maxSplits: 1).map(String.init)
                guard fields.count == 2, Self.isObjectID(fields[0]) else { return nil }
                return GitStash(id: fields[0], message: fields[1])
            } ?? []
        return GitSourceSnapshot(
            root: root, branch: branch, head: head,
            indexFingerprint: SHA256.hash(data: Data(index.utf8)).map { String(format: "%02x", $0) }.joined(),
            files: files,
            sync: GitSyncStatus(
                upstream: upstream?.isEmpty == false ? upstream : nil,
                ahead: ahead, behind: behind, remotes: remotes),
            stashes: stashes)
    }

    static func conflictFiles(at directory: String) throws -> [GitConflictFile] {
        let root = try root(at: directory)
        let conflicts = Array(try sourceControl(at: root).files.filter(\.isConflicted).prefix(12))
        return try conflicts.map { file in
            let url = try safeFile(file.path, root: root)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw GitFailure(message: "Cannot send a symbolic link to the conflict resolver: \(file.path)")
            }
            let currentData = try? Data(contentsOf: url, options: [.mappedIfSafe])
            func decode(_ data: Data?) throws -> String? {
                guard let data else { return nil }
                guard data.count <= 131_072, let text = String(data: data, encoding: .utf8) else {
                    throw GitFailure(message: "\(file.path) is binary or larger than 128 KB; resolve it manually.")
                }
                return text
            }
            func stage(_ number: Int) -> String? {
                guard let data = try? run(at: root, ["show", ":\(number):./\(file.path)"]).data(using: .utf8) else {
                    return nil
                }
                return try? decode(data)
            }
            return GitConflictFile(
                path: file.path, ancestor: stage(1), ours: stage(2), theirs: stage(3),
                current: try decode(currentData), currentFingerprint: currentData.map(fingerprint))
        }
    }

    static func applyConflictResolutions(
        _ resolutions: [String: String], expected: [GitConflictFile], at directory: String
    ) throws -> URL {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        let originals = try validatedConflictFiles(resolutions, expected: expected, root: root)

        let gitDir = try run(at: root, ["rev-parse", "--path-format=absolute", "--git-dir"]).trimmingCharacters(
            in: .newlines)
        let backup = URL(fileURLWithPath: gitDir).appendingPathComponent("spark-conflict-backups")
            .appendingPathComponent(UUID().uuidString)
        let backupFiles = backup.appendingPathComponent("files")
        try FileManager.default.createDirectory(
            at: backupFiles, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for original in originals {
            let saved = backupFiles.appendingPathComponent(original.path)
            try FileManager.default.createDirectory(
                at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.data.write(to: saved, options: .atomic)
        }

        var written: [(URL, Data)] = []
        do {
            for original in originals {
                guard let current = try? Data(contentsOf: original.url, options: [.mappedIfSafe]),
                    current == original.data
                else {
                    throw GitFailure(
                        message: "\(original.path) changed during resolution. No more files were modified.")
                }
                written.append((original.url, original.data))
                let handle = try FileHandle(forWritingTo: original.url)
                do {
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: Data(resolutions[original.path]!.utf8))
                    try handle.close()
                } catch { try? handle.close(); throw error }
            }
        } catch {
            for (url, data) in written.reversed() {
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.truncate(atOffset: 0); try? handle.write(contentsOf: data); try? handle.close()
                }
            }
            throw GitFailure(
                message:
                    "Could not apply every resolution. Original files were restored where possible. Recovery copies: \(backup.path). \(error.localizedDescription)"
            )
        }
        return backup
    }

    private static func validatedConflictFiles(
        _ resolutions: [String: String], expected: [GitConflictFile], root: String
    ) throws -> [(path: String, url: URL, data: Data)] {
        guard !expected.isEmpty, resolutions.count == expected.count,
            Set(resolutions.keys) == Set(expected.map(\.path))
        else { throw GitFailure(message: "The AI resolutions are incomplete. Generate them again before applying.") }
        let currentConflicts = try sourceControl(at: root).files.filter(\.isConflicted)
        guard expected.allSatisfy({ expectedFile in currentConflicts.contains { $0.path == expectedFile.path } }) else {
            throw GitFailure(message: "Conflict status changed while the AI was working. Refresh before applying.")
        }
        var originals: [(path: String, url: URL, data: Data)] = []
        for file in expected {
            guard let contents = file.current, let expectedFingerprint = file.currentFingerprint,
                let resolution = resolutions[file.path], resolution.utf8.count <= 131_072
            else { throw GitFailure(message: "\(file.path) does not have a complete current text version.") }
            let url = try safeFile(file.path, root: root)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                fingerprint(data) == expectedFingerprint,
                data == Data(contents.utf8)
            else {
                throw GitFailure(
                    message: "\(file.path) changed while the AI was working. Generate the resolutions again.")
            }
            originals.append((file.path, url, data))
        }
        return originals
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func partialStage(at directory: String, path: String) throws -> GitPartialStage {
        let root = try root(at: directory)
        try validateGitPath(path)
        guard let file = try sourceControl(at: root).files.first(where: { $0.path == path }), file.isUnstaged else {
            throw GitFailure(message: "This file has no unstaged changes to stage.")
        }
        guard !file.isConflicted else {
            throw GitFailure(message: "Resolve this file's conflicts before staging hunks.")
        }
        let output: String
        if file.isUntracked {
            output = try run(
                at: root,
                [
                    "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color",
                    "--unified=3", "--", "/dev/null", path
                ], accepted: [0, 1])
        } else {
            output = try run(
                at: root,
                [
                    "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames",
                    "--unified=3", "--", path
                ])
        }
        let lines = output.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
        guard !starts.isEmpty else {
            throw GitFailure(
                message: "Git could not produce text hunks for this file. Binary files cannot be staged by hunk.")
        }
        let hunks = starts.enumerated().map { position, start in
            let end = position + 1 < starts.count ? starts[position + 1] : lines.endIndex
            return GitPatchHunk(
                id: position, header: lines[start], patch: lines[start..<end].joined(separator: "\n"))
        }
        return GitPartialStage(patch: output, hunks: hunks)
    }

    static func stageHunks(
        _ hunks: [GitPatchHunk], expectedPatch: String, path: String, at directory: String
    ) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let current = try partialStage(at: directory, path: path)
        guard current.patch == expectedPatch else {
            throw GitFailure(
                message: "This file changed while the hunk picker was open. Reopen it and select the current hunks.")
        }
        let selected = Set(hunks.map(\.id))
        guard !selected.isEmpty, selected.isSubset(of: Set(current.hunks.map(\.id))) else {
            throw GitFailure(message: "Select at least one current hunk to stage.")
        }
        let lines = current.patch.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.hasPrefix("@@ ") }) else {
            throw GitFailure(message: "The file no longer has stageable hunks.")
        }
        let patch =
            lines[..<first].joined(separator: "\n") + "\n"
            + current.hunks.filter { selected.contains($0.id) }.map(\.patch).joined(separator: "\n")
        _ = try run(at: directory, ["apply", "--cached", "-"], input: Data(patch.utf8))
    }

    static func stashChanges(at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard try !sourceControl(at: directory).files.isEmpty else {
            throw GitFailure(message: "There are no changes to save in a stash.")
        }
        _ = try run(at: directory, ["stash", "push", "--include-untracked", "-m", "Saved from Spark"], timeout: 120)
    }

    static func popStash(_ stash: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard Self.isObjectID(stash) else { throw GitFailure(message: "This stash reference is invalid.") }
        guard let reference = try stashReference(for: stash, at: directory) else { return }
        _ = try run(at: directory, ["stash", "pop", "--index", reference], timeout: 120)
    }

    static func dropStash(_ stash: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard Self.isObjectID(stash) else { throw GitFailure(message: "This stash reference is invalid.") }
        guard let reference = try stashReference(for: stash, at: directory) else { return }
        _ = try run(at: directory, ["stash", "drop", reference], timeout: 120)
    }

    private static func stashReference(for objectID: String, at directory: String) throws -> String? {
        let entries = try run(at: directory, ["stash", "list", "--format=%gd%x00%H"])
        for line in entries.components(separatedBy: .newlines) {
            let fields = line.split(separator: "\0", maxSplits: 1).map(String.init)
            if fields.count == 2, fields[1] == objectID { return fields[0] }
        }
        // The stash may have been popped or dropped since this snapshot was read.
        // Treat it as complete so the store refresh removes the stale row.
        return nil
    }

    static func fetch(at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        _ = try run(at: directory, ["fetch"], timeout: 180)
    }

    static func fetchAll(at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        _ = try run(at: directory, ["fetch", "--all", "--prune"], timeout: 180)
    }

    static func pull(at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard try sourceControl(at: directory).files.isEmpty else {
            throw GitFailure(message: "Stash or commit the current changes before pulling.")
        }
        guard (try? run(at: directory, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])) != nil
        else {
            throw GitFailure(message: "Set an upstream branch before pulling.")
        }
        _ = try run(at: directory, ["pull", "--ff-only"], timeout: 180)
    }

    static func push(at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let branch = try run(at: directory, ["symbolic-ref", "--quiet", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try run(at: directory, ["config", "--get", "branch.\(branch).remote"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let merge = try run(at: directory, ["config", "--get", "branch.\(branch).merge"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote != ".", !remote.isEmpty, merge.hasPrefix("refs/heads/") else {
            throw GitFailure(message: "Set a remote upstream branch before pushing.")
        }
        _ = try run(at: directory, ["push", remote, "HEAD:" + merge], timeout: 180)
    }

    static func publishBranch(to remote: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let remotes = try run(at: directory, ["remote"]).split(whereSeparator: \.isNewline).map(String.init)
        guard remotes.contains(remote) else { throw GitFailure(message: "That Git remote is no longer available.") }
        let branch = try run(at: directory, ["symbolic-ref", "--quiet", "--short", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(at: directory, ["check-ref-format", "--branch", branch])
        _ = try run(at: directory, ["push", "--set-upstream", remote, "HEAD:refs/heads/" + branch], timeout: 180)
    }

    static func stage(_ path: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        try validateGitPath(path)
        _ = try run(at: root, ["add", "--", path])
    }

    static func stageAll(at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        _ = try run(at: root, ["add", "--all", "--", "."])
    }

    static func unstage(_ path: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        try validateGitPath(path)
        if (try? run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"])) != nil {
            _ = try run(at: root, ["restore", "--staged", "--", path])
        } else {
            _ = try run(at: root, ["rm", "--cached", "--ignore-unmatch", "--force", "--", path])
        }
    }

    static func stagedDiff(at directory: String) throws -> String {
        let root = try root(at: directory)
        return try run(
            at: root,
            ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=2", "--"])
    }

    static func commit(at directory: String, message: String, expected: GitSourceSnapshot) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw GitFailure(message: "Enter a commit message first.") }
        guard expected.root == root else {
            throw GitFailure(message: "The repository changed. Refresh Source Control.")
        }
        try requireNoOperation(root)
        let current = try sourceControl(at: root)
        guard current.head == expected.head, current.indexFingerprint == expected.indexFingerprint else {
            throw GitFailure(message: "The staged changes changed. Review them and try the commit again.")
        }
        guard !current.stagedFiles.isEmpty else { throw GitFailure(message: "Stage at least one file to commit.") }
        guard !current.files.contains(where: \.isConflicted) else {
            throw GitFailure(message: "Resolve all merge conflicts before committing.")
        }
        _ = try run(at: root, ["commit", "-m", message], timeout: 120)
    }

}
