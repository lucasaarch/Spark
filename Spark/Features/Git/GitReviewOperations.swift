import Foundation

extension GitRepository {
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

}
