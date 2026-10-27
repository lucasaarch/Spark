import Foundation
import Darwin

struct GitFailure: LocalizedError {
    let message: String
    var isNotRepository = false
    var errorDescription: String? { message }
}

struct GitWorktree: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let branch: String
}

struct GitChange: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let status: String
    var untracked: Bool { status == "?" }
}

struct GitReview: Equatable, Sendable {
    let root: String
    let base: String
    let branch: String
    let changes: [GitChange]
}

struct GitContext: Equatable, Sendable {
    let root: String
    let branch: String
    let mainRoot: String
    var isWorktree: Bool { root != mainRoot }
}

struct GitMergePlan: Sendable {
    let source: GitContext
    let destination: GitWorktree
    let sourceCommit: String
    let destinationCommit: String
}

struct GitDiscardPlan: Sendable {
    let review: GitReview
    let changes: [GitChange]
    let fingerprints: [String: GitFileFingerprint]
}

struct GitFileFingerprint: Equatable, Sendable {
    let workingPatch: String
    let stagedPatch: String
}

/// All calls run off the main actor. Arguments never pass through a shell.
enum GitRepository {
    private static let mutationLock = NSLock()

    static func observationDirectories(at directory: String) -> [String] {
        guard let root = try? root(at: directory) else { return [directory] }
        var paths = [root]
        for option in ["--absolute-git-dir", "--git-common-dir"] {
            if let value = try? run(at: root, ["rev-parse", option]).trimmingCharacters(in: .newlines), !value.isEmpty {
                paths.append(
                    URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: root, isDirectory: true))
                        .standardizedFileURL.path)
            }
        }
        return paths
    }

    static func inspect(at directory: String) throws -> GitContext {
        let root = try root(at: directory)
        let branch =
            (try? run(at: root, ["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines))
            ?? "Detached HEAD"
        let main = try worktrees(at: root).first?.path ?? root
        return GitContext(root: root, branch: branch, mainRoot: main)
    }

    static func suggestedName() -> String {
        let first = [
            "amber", "brave", "bright", "calm", "clear", "coral", "cosmic", "crimson", "crystal", "dawn", "distant",
            "electric", "emerald", "frosty", "gentle", "golden", "hidden", "indigo", "ivory", "jade", "lively", "lunar",
            "misty", "nimble", "quiet", "rapid", "silver", "solar", "steady", "swift", "velvet", "vivid"
        ]
        let second = [
            "badger", "birch", "breeze", "brook", "cedar", "comet", "crane", "dune", "eagle", "falcon", "fern", "finch",
            "forest", "fox", "grove", "harbor", "heron", "island", "lake", "lynx", "maple", "meadow", "moon", "otter",
            "owl", "panda", "pine", "raven", "river", "sparrow", "tiger", "willow"
        ]
        return first.randomElement()! + "-" + second.randomElement()!
    }
    static func root(at directory: String) throws -> String {
        do {
            return try run(at: directory, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
        } catch let error as GitFailure where error.message.contains("not a git repository") {
            throw GitFailure(
                message:
                    "This terminal's folder is not inside a Git repository. Open a project folder in this terminal to review its changes.",
                isNotRepository: true)
        }
    }

    static func worktrees(at directory: String) throws -> [GitWorktree] {
        let output = try run(at: directory, ["worktree", "list", "--porcelain", "-z"])
        return output.components(separatedBy: "\0\0").compactMap { record in
            let fields = record.components(separatedBy: "\0")
            guard let path = fields.first(where: { $0.hasPrefix("worktree ") }), !fields.contains("bare") else {
                return nil
            }
            let branch = fields.first(where: { $0.hasPrefix("branch refs/heads/") }).map { String($0.dropFirst(18)) }
            return GitWorktree(path: String(path.dropFirst(9)), branch: branch ?? "Detached HEAD")
        }
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

    static func diff(_ change: GitChange, review: GitReview, binary: Bool = false) throws -> String {
        guard !change.path.hasPrefix("/"), !change.path.split(separator: "/").contains(".."),
            !change.path.contains("\0")
        else {
            throw GitFailure(message: "Invalid file path in Git output.")
        }
        if change.untracked {
            let root = URL(fileURLWithPath: review.root).resolvingSymlinksInPath().path
            let parent = URL(fileURLWithPath: review.root).appendingPathComponent(change.path)
                .deletingLastPathComponent().resolvingSymlinksInPath().path
            guard parent == root || parent.hasPrefix(root + "/") else {
                throw GitFailure(message: "This file's parent now points outside the repository. Refresh the review.")
            }
            return try run(
                at: review.root,
                ["diff", "--no-index", "--no-ext-diff", "--no-textconv"] + (binary ? ["--binary"] : []) + [
                    "--", "/dev/null", change.path
                ], accepted: [0, 1])
        }
        return try run(
            at: review.root,
            ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--submodule=short"]
                + (binary ? ["--binary"] : []) + [review.base, "--", change.path])
    }

    static func prepareMerge(source: GitContext, record: WorktreeRecord?) throws -> GitMergePlan {
        guard source.isWorktree else {
            throw GitFailure(message: "This is the main working tree. Open a linked worktree to merge its branch.")
        }
        let trees = try worktrees(at: source.root)
        let savedBranch = record.flatMap { $0.path == source.root ? $0.baseBranch : nil }
        guard
            let destination = trees.first(where: {
                savedBranch != nil ? $0.branch == savedBranch : $0.path == source.mainRoot
            }),
            destination.path != source.root, destination.branch != "Detached HEAD"
        else {
            throw GitFailure(
                message: "The original branch is not checked out in another worktree. Check it out before merging.")
        }
        try requireClean(source.root)
        try requireClean(destination.path)
        let sourceCommit = try commit(at: source.root)
        let destinationCommit = try commit(at: destination.path)
        return GitMergePlan(
            source: source, destination: destination, sourceCommit: sourceCommit, destinationCommit: destinationCommit)
    }

    static func sourceTexts(_ change: GitChange, review: GitReview) -> (old: String?, new: String?) {
        let old = try? run(at: review.root, ["show", "\(review.base):\(change.path)"])
        guard let file = try? safeFile(change.path, root: review.root) else { return (old, nil) }
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return (old, try? FileManager.default.destinationOfSymbolicLink(atPath: file.path))
        }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return (old, nil) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            let data = try? handle.read(upToCount: 524_289), data.count <= 524_288
        else { return (old, nil) }
        return (old, String(data: data, encoding: .utf8))
    }

    static func merge(_ plan: GitMergePlan) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let current = try inspect(at: plan.source.root)
        let target = try inspect(at: plan.destination.path)
        guard current == plan.source, target.branch == plan.destination.branch,
            try commit(at: current.root) == plan.sourceCommit,
            try commit(at: target.root) == plan.destinationCommit
        else {
            throw GitFailure(
                message: "The branches changed since the merge was prepared. Reopen Worktree and try again.")
        }
        try requireClean(current.root); try requireClean(target.root)
        do {
            // Detect conflicts without touching either working tree.
            _ = try run(at: target.root, ["merge-tree", "--write-tree", plan.destinationCommit, plan.sourceCommit])
        } catch {
            throw GitFailure(
                message:
                    "Git could not prepare a clean merge. No working files were changed. Resolve the branch differences in the terminal.\n\(error.localizedDescription)"
            )
        }
        // Recheck after preflight. Git's own locks and merge checks remain in
        // force; never switch branches, stash, reset or auto-abort user work.
        try requireClean(target.root)
        guard try commit(at: target.root) == plan.destinationCommit else {
            throw GitFailure(message: "The destination branch moved. Refresh before merging.")
        }
        do {
            _ = try run(at: target.root, ["merge", "--no-edit", "--no-stat", plan.sourceCommit], timeout: 120)
        } catch {
            throw GitFailure(
                message:
                    "Merge needs attention in \(target.root). Git's state has been preserved.\n\(error.localizedDescription)"
            )
        }
    }

    private static func commit(at root: String) throws -> String {
        try run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .newlines)
    }

    private static func requireNoOperation(_ root: String) throws {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            let path = try run(at: root, ["rev-parse", "--path-format=absolute", "--git-path", marker])
                .trimmingCharacters(in: .newlines)
            if FileManager.default.fileExists(atPath: path) {
                throw GitFailure(message: "Finish the current Git operation in \(root) first.")
            }
        }
    }

    private static func requireClean(_ root: String) throws {
        try requireNoOperation(root)
        guard try run(at: root, ["status", "--porcelain=v1", "--untracked-files=normal"]).isEmpty else {
            throw GitFailure(
                message: "Commit or stash local changes in \(root) before merging. Both worktrees must be clean.")
        }
    }

    static func prepareDiscard(review: GitReview, changes: [GitChange]) throws -> GitDiscardPlan {
        try requireNoOperation(review.root)
        let current = try self.review(at: review.root, worktree: nil)
        guard current.base == review.base, current.branch == review.branch,
            changes.allSatisfy({ current.changes.contains($0) })
        else {
            throw GitFailure(message: "These files changed since the review was loaded. Refresh before discarding.")
        }
        var fingerprints: [String: GitFileFingerprint] = [:]
        for change in changes {
            let url = try safeFile(change.path, root: review.root)
            let index = try run(at: review.root, ["ls-files", "--stage", "--", change.path])
            guard !index.hasPrefix("160000 ") else {
                throw GitFailure(message: "Manage submodule changes in the terminal: \(change.path)")
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory != true || values?.isSymbolicLink == true else {
                throw GitFailure(message: "Directories and submodules must be managed in the terminal: \(change.path)")
            }
            fingerprints[change.path] = try GitFileFingerprint(
                workingPatch: diff(change, review: review, binary: true),
                stagedPatch: run(
                    at: review.root,
                    ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", review.base, "--", change.path]))
        }
        return GitDiscardPlan(review: review, changes: changes, fingerprints: fingerprints)
    }

    /// Keep recoverable file copies and index/worktree patches before restoring.
    /// The confirmation is tied to exact contents; edits made afterwards abort.
    static func discard(_ plan: GitDiscardPlan) throws -> URL {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let fresh = try prepareDiscard(review: plan.review, changes: plan.changes)
        guard fresh.fingerprints == plan.fingerprints else {
            throw GitFailure(message: "Files changed after confirmation. Refresh and review the new changes first.")
        }
        let gitDir = try run(at: plan.review.root, ["rev-parse", "--path-format=absolute", "--git-dir"])
            .trimmingCharacters(in: .newlines)
        let backup = URL(fileURLWithPath: gitDir).appendingPathComponent("spark-discarded").appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(
            at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for change in plan.changes {
            let source = try safeFile(change.path, root: plan.review.root)
            let target = backup.appendingPathComponent("files").appendingPathComponent(change.path)
            if (try? FileManager.default.attributesOfItem(atPath: source.path)) != nil {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        let fingerprints = plan.changes.compactMap { plan.fingerprints[$0.path] }
        try fingerprints.map(\.workingPatch).joined().write(
            to: backup.appendingPathComponent("working.patch"), atomically: true, encoding: .utf8)
        try fingerprints.map(\.stagedPatch).joined().write(
            to: backup.appendingPathComponent("staged.patch"), atomically: true, encoding: .utf8)
        let checked = try prepareDiscard(review: plan.review, changes: plan.changes)
        guard checked.fingerprints == plan.fingerprints else {
            throw GitFailure(message: "Files changed during backup. Nothing was discarded.")
        }
        do {
            let tracked = plan.changes.filter { !$0.untracked }.map(\.path)
            if !tracked.isEmpty {
                _ = try run(
                    at: plan.review.root,
                    ["restore", "--source=\(plan.review.base)", "--staged", "--worktree", "--"] + tracked)
            }
            for change in plan.changes where change.untracked {
                try FileManager.default.removeItem(at: safeFile(change.path, root: plan.review.root))
            }
        } catch {
            throw GitFailure(
                message: "Discard did not finish. Recovery copies are in \(backup.path).\n\(error.localizedDescription)"
            )
        }
        return backup
    }

    private static func safeFile(_ path: String, root: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..")
        else {
            throw GitFailure(message: "Invalid repository path.")
        }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let file = base.appendingPathComponent(path)
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == base.path || parent.hasPrefix(base.path + "/") else {
            throw GitFailure(message: "The file points outside this repository.")
        }
        return file
    }

    /// Files avoid pipe deadlocks, with bounded output, runtime and cleanup.
    /// Optional Git locks, hooks and external diff/textconv programs are disabled.
    static func run(at directory: String, _ arguments: [String], accepted: Set<Int32> = [0], timeout: TimeInterval = 30)
        throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SparkGit-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("out"), errors = temporary.appendingPathComponent("err")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments =
            [
                "--no-pager", "--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                "-C", directory
            ] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var failure: String?
        while process.isRunning {
            let sizes = [output, errors].map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            if sizes.contains(where: { $0 > 4_194_304 }) {
                failure = "This Git result is too large to display (4 MB limit)."
            }
            if Date() > deadline { failure = "Git took too long to finish. Check the repository and try again." }
            if failure != nil { kill(process.processIdentifier, SIGKILL); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        if let failure { throw GitFailure(message: failure) }
        func read(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4_194_305) ?? Data()
            guard data.count <= 4_194_304 else {
                throw GitFailure(message: "This Git result is too large to display (4 MB limit).")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw GitFailure(message: "Git returned text that is not UTF-8 and cannot be displayed safely.")
            }
            return text
        }
        guard accepted.contains(process.terminationStatus) else {
            let detail = try read(errors).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitFailure(
                message: String(
                    (detail.isEmpty ? "Git exited with status \(process.terminationStatus)." : detail).prefix(2000)))
        }
        return try read(output)
    }
}
