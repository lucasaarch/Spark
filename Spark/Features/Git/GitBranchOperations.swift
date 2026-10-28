import Foundation

extension GitRepository {
    static func quickOpenFiles(at directory: String) throws -> [GitQuickOpenFile] {
        let root = try root(at: directory)
        let paths = try run(at: root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        let changes = (try? review(at: root, worktree: nil).changes) ?? []
        var statuses = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0.statusLetter) })
        var result = paths.map { GitQuickOpenFile(path: $0, status: statuses.removeValue(forKey: $0)) }
        result += statuses.map { GitQuickOpenFile(path: $0.key, status: $0.value) }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func branches(at directory: String) throws -> [GitBranch] {
        let root = try root(at: directory)
        let remotes = try run(at: root, ["remote"]).split(whereSeparator: \.isNewline)
            .map(String.init).sorted { $0.count > $1.count }
        let output = try run(
            at: root,
            [
                "for-each-ref", "--format=%(refname)%00%(HEAD)%00%(symref)",
                "refs/heads", "refs/remotes"
            ])
        var result: [GitBranch] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[2].isEmpty else { continue }
            let ref = fields[0]
            if ref.hasPrefix("refs/heads/") {
                result.append(
                    GitBranch(
                        ref: ref, name: String(ref.dropFirst("refs/heads/".count)),
                        remote: nil, isCurrent: fields[1] == "*"))
            } else if ref.hasPrefix("refs/remotes/"),
                let remote = remotes.first(where: { ref.hasPrefix("refs/remotes/\($0)/") }) {
                let name = String(ref.dropFirst("refs/remotes/\(remote)/".count))
                result.append(GitBranch(ref: ref, name: name, remote: remote, isCurrent: false))
            }
        }
        return result.sorted {
            if $0.isRemote != $1.isRemote { return !$0.isRemote }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func compareBranches(at directory: String, baseRef: String, targetRef: String) throws -> GitBranchComparison {
        let root = try root(at: directory)
        let available = try branches(at: root)
        guard let base = available.first(where: { $0.ref == baseRef }),
            let target = available.first(where: { $0.ref == targetRef }), base.ref != target.ref
        else { throw GitFailure(message: "Refresh the branch list and choose two different existing branches.") }
        let mergeBase = try run(at: root, ["merge-base", base.ref, target.ref]).trimmingCharacters(in: .newlines)
        let baseOnly = try commits(in: "\(target.ref)..\(base.ref)", at: root)
        let targetOnly = try commits(in: "\(base.ref)..\(target.ref)", at: root)
        let fields = try run(at: root, ["diff", "--name-status", "-z", "--no-renames", mergeBase, target.ref])
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        let files = stride(from: 0, to: fields.count - fields.count % 2, by: 2)
            .map { GitCommitFile(path: fields[$0 + 1], status: fields[$0]) }
        return GitBranchComparison(base: base, target: target, baseOnly: baseOnly, targetOnly: targetOnly, files: files)
    }

    static func compareBranchPatch(
        at directory: String, baseRef: String, targetRef: String, path: String
    ) throws -> GitBranchComparisonPatch {
        let root = try root(at: directory)
        try validateGitPath(path)
        let available = try branches(at: root)
        guard available.contains(where: { $0.ref == baseRef }), available.contains(where: { $0.ref == targetRef }),
            baseRef != targetRef
        else { throw GitFailure(message: "The selected branches changed. Refresh the comparison.") }
        let base = try run(at: root, ["merge-base", baseRef, targetRef]).trimmingCharacters(in: .newlines)
        let patch = try run(
            at: root,
            [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color",
                "--unified=3", base, targetRef, "--", path
            ])
        let old = try? run(at: root, ["show", "\(base):./\(path)"])
        let new = try? run(at: root, ["show", "\(targetRef):./\(path)"])
        return GitBranchComparisonPatch(patch: patch, baseContents: old, targetContents: new)
    }

    private static func commits(in revision: String, at root: String) throws -> [GitCommit] {
        let format = "%H%x00%h%x00%an%x00%aI%x00%P%x00%s"
        return try run(at: root, ["log", "--max-count=100", "--format=\(format)", revision])
            .split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 6, Self.isObjectID(fields[0]) else { return nil }
                return GitCommit(
                    hash: fields[0], shortHash: fields[1], author: fields[2], date: fields[3],
                    parents: fields[4].split(whereSeparator: \.isWhitespace).map(String.init), subject: fields[5])
            }
    }

    static func switchBranch(_ branch: GitBranch, in expected: GitContext) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard try inspect(at: expected.root) == expected else {
            throw GitFailure(message: "The repository branch changed. Refresh the branch list and try again.")
        }
        try requireClean(expected.root)
        let currentBranches = try branches(at: expected.root)
        guard currentBranches.contains(where: { $0.ref == branch.ref && $0.isRemote == branch.isRemote }) else {
            throw GitFailure(message: "That branch no longer exists. Refresh the branch list.")
        }
        if branch.isRemote,
            currentBranches.contains(where: { !$0.isRemote && $0.name == branch.name }) {
            throw GitFailure(
                message: "A local branch named \(branch.name) already exists. Select it from Local Branches.")
        }
        if branch.isRemote {
            try validateBranchName(branch.name, at: expected.root)
            _ = try run(at: expected.root, ["switch", "--track", "-c", branch.name, branch.ref], timeout: 120)
        } else {
            try validateBranchName(branch.name, at: expected.root)
            _ = try run(at: expected.root, ["switch", "--", branch.name], timeout: 120)
        }
    }

    static func createBranch(_ name: String, expected: GitContext) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard try inspect(at: expected.root) == expected else {
            throw GitFailure(message: "The repository branch changed. Refresh and try again.")
        }
        try requireClean(expected.root)
        try validateBranchName(name, at: expected.root)
        _ = try run(at: expected.root, ["switch", "-c", name], timeout: 120)
    }

    static func worktreeStatuses(at directory: String) throws -> [GitWorktreeStatus] {
        let trees = try worktrees(at: directory)
        guard let main = trees.first else { return [] }
        return try trees.map { tree in
            let clean = try sourceControl(at: tree.path).files.isEmpty
            let merged: Bool
            if tree.path == main.path {
                merged = true
            } else if tree.branch == "Detached HEAD" || main.branch == "Detached HEAD" {
                merged = false
            } else {
                let tip = try run(at: main.path, ["rev-parse", "--verify", "refs/heads/\(tree.branch)^{commit}"])
                    .trimmingCharacters(in: .newlines)
                let base = try run(
                    at: main.path, ["merge-base", "refs/heads/\(tree.branch)", "refs/heads/\(main.branch)"]
                )
                .trimmingCharacters(in: .newlines)
                merged = tip == base
            }
            return GitWorktreeStatus(
                worktree: tree, isMain: tree.path == main.path,
                isClean: clean, isMergedIntoMain: merged)
        }
    }

    static func removeMergedWorktree(_ status: GitWorktreeStatus, at directory: String, protectedPaths: Set<String>)
        throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let trees = try worktrees(at: directory)
        guard let main = trees.first, !status.isMain,
            let current = trees.first(where: { $0.path == status.worktree.path }),
            current.branch == status.worktree.branch, !current.isLocked, !current.isPrunable
        else { throw GitFailure(message: "This worktree changed. Refresh the worktree list.") }
        let path = URL(fileURLWithPath: current.path).resolvingSymlinksInPath().path
        guard !protectedPaths.contains(path) else {
            throw GitFailure(
                message: "A Spark terminal is still open in this worktree. Close it before removing the worktree.")
        }
        guard try sourceControl(at: current.path).files.isEmpty else {
            throw GitFailure(message: "This worktree has local changes. Commit or stash them before cleanup.")
        }
        guard current.branch != "Detached HEAD", main.branch != "Detached HEAD" else {
            throw GitFailure(message: "Detached worktrees cannot be cleaned up as merged branches.")
        }
        let tip = try run(at: main.path, ["rev-parse", "--verify", "refs/heads/\(current.branch)^{commit}"])
            .trimmingCharacters(in: .newlines)
        let base = try run(at: main.path, ["merge-base", "refs/heads/\(current.branch)", "refs/heads/\(main.branch)"])
            .trimmingCharacters(in: .newlines)
        guard tip == base else {
            throw GitFailure(message: "This branch is not merged into \(main.branch); the worktree was kept.")
        }
        _ = try run(at: main.path, ["worktree", "remove", "--", current.path], timeout: 120)
        do {
            _ = try run(at: main.path, ["branch", "-d", current.branch])
        } catch {
            throw GitFailure(
                message:
                    "The merged worktree was removed, but branch \(current.branch) was kept. \(error.localizedDescription)"
            )
        }
    }

    static func commits(at directory: String, limit: Int = 100) throws -> [GitCommit] {
        let root = try root(at: directory)
        let boundedLimit = min(max(limit, 1), 500)
        let format = "%H%x00%h%x00%an%x00%aI%x00%P%x00%s"
        let output = try run(at: root, ["log", "--max-count=\(boundedLimit)", "--format=\(format)"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, Self.isObjectID(fields[0]) else { return nil }
            return GitCommit(
                hash: fields[0], shortHash: fields[1], author: fields[2], date: fields[3],
                parents: fields[4].split(whereSeparator: \.isWhitespace).map(String.init), subject: fields[5])
        }
    }

    static func commitFiles(_ commit: GitCommit, at directory: String) throws -> [GitCommitFile] {
        let root = try root(at: directory)
        guard Self.isObjectID(commit.hash) else { throw GitFailure(message: "Invalid commit reference.") }
        let output = try run(
            at: root,
            [
                "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z",
                "--no-renames", commit.hash
            ])
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return stride(from: 0, to: fields.count - fields.count % 2, by: 2)
            .map { GitCommitFile(path: fields[$0 + 1], status: fields[$0]) }
    }

    static func commitPatch(_ commit: GitCommit, file: String, at directory: String) throws -> String {
        let root = try root(at: directory)
        guard Self.isObjectID(commit.hash) else { throw GitFailure(message: "Invalid commit reference.") }
        try validateGitPath(file)
        if let parent = commit.parents.first {
            return try run(
                at: root,
                [
                    "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color",
                    "--unified=3", parent, commit.hash, "--", file
                ])
        }
        return try run(
            at: root,
            [
                "diff-tree", "--root", "--no-commit-id", "--no-ext-diff", "--no-textconv",
                "--no-renames", "--no-color", "--unified=3", "-r", commit.hash, "--", file
            ])
    }

    static func historyActionState(at directory: String) throws -> GitHistoryActionState {
        let root = try root(at: directory)
        let isClean = try sourceControl(at: root).files.isEmpty
        guard
            let head = try? run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"])
                .trimmingCharacters(in: .newlines), !head.isEmpty
        else {
            return GitHistoryActionState(isClean: isClean, isHeadPublished: false)
        }
        let refs = try run(at: root, ["for-each-ref", "--contains=\(head)", "--format=%(refname)", "refs/remotes"])
        return GitHistoryActionState(
            isClean: isClean, isHeadPublished: !refs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func undoLastCommit(expectedHead: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        let current = try run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .newlines)
        guard current == expectedHead else {
            throw GitFailure(message: "The branch moved. Refresh commit history first.")
        }
        try requireClean(root)
        let commit = try commits(at: root, limit: 1).first
        guard let parent = commit?.parents.first else {
            throw GitFailure(message: "The initial commit cannot be undone this way.")
        }
        guard try historyActionState(at: root).isHeadPublished == false else {
            throw GitFailure(
                message: "This commit exists on a remote branch. Use Revert Commit to preserve shared history.")
        }
        _ = try run(at: root, ["reset", "--soft", parent])
    }

    static func revertCommit(_ commit: GitCommit, expectedHead: String, at directory: String) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let root = try root(at: directory)
        let current = try run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .newlines)
        guard current == expectedHead else {
            throw GitFailure(message: "The branch moved. Refresh commit history first.")
        }
        try requireClean(root)
        guard Self.isObjectID(commit.hash), commit.parents.count <= 1 else {
            throw GitFailure(message: "Merge commits cannot be reverted from this view.")
        }
        _ = try run(at: root, ["revert", "--no-edit", commit.hash], timeout: 120)
    }

    static func createWorktree(at directory: String, branch: String, expected: GitContext? = nil) throws
        -> WorktreeRecord {
        mutationLock.lock(); defer { mutationLock.unlock() }
        if let expected, try inspect(at: directory) != expected {
            throw GitFailure(
                message:
                    "The source terminal's repository or branch changed. Reopen New Worktree to use its current state.")
        }
        guard !branch.isEmpty, branch.count <= 256, !branch.hasPrefix("-"),
            !branch.contains("@{"), !branch.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw GitFailure(message: "Enter a valid new Git branch name.")
        }
        let root = try root(at: directory)
        _ = try run(at: root, ["check-ref-format", "--branch", branch])
        let base = try run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .newlines)
        let originBranch = try? run(at: root, ["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines)
        let mainRoot = try worktrees(at: root).first?.path ?? root
        let repository = URL(fileURLWithPath: mainRoot)
        let folder = repository.deletingLastPathComponent().appendingPathComponent(
            repository.lastPathComponent + "-worktrees")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = String(branch.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(64))
        let target = folder.appendingPathComponent(slug)
        // Git rejects an existing branch/path. Never reset branches or remove
        // files on failure: a failed checkout may still have recoverable work.
        _ = try run(at: root, ["worktree", "add", "-b", branch, target.path, base], timeout: 120)
        return WorktreeRecord(
            repository: root, path: target.path, branch: branch, baseCommit: base, baseBranch: originBranch)
    }

}
