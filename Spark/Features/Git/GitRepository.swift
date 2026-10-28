import Foundation
import CryptoKit
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
    let isLocked: Bool
    let isPrunable: Bool
}

struct GitBranch: Identifiable, Equatable, Sendable {
    var id: String { ref }
    let ref: String
    let name: String
    let remote: String?
    let isCurrent: Bool
    var isRemote: Bool { remote != nil }
}

struct GitCommit: Identifiable, Equatable, Sendable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let author: String
    let date: String
    let parents: [String]
    let subject: String
}

struct GitCommitFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let status: String
}

struct GitWorktreeStatus: Identifiable, Sendable {
    var id: String { worktree.path }
    let worktree: GitWorktree
    let isMain: Bool
    let isClean: Bool
    let isMergedIntoMain: Bool
}

struct GitQuickOpenFile: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let status: String?
}

struct GitHistoryActionState: Sendable {
    let isClean: Bool
    let isHeadPublished: Bool
}

struct GitConflictFile: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let ancestor: String?
    let ours: String?
    let theirs: String?
    let current: String?
    let currentFingerprint: String?
}

struct GitBranchComparison: Sendable {
    let base: GitBranch
    let target: GitBranch
    let baseOnly: [GitCommit]
    let targetOnly: [GitCommit]
    let files: [GitCommitFile]
}

struct GitBranchComparisonPatch: Sendable {
    let patch: String
    let baseContents: String?
    let targetContents: String?
}

struct GitChange: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let status: String
    var untracked: Bool { status == "?" }
    var statusLetter: String {
        let code = status.first.map(String.init) ?? "M"
        return code == "?" || code == "U" ? "U" : code
    }
}

struct GitReview: Equatable, Sendable {
    let root: String
    let base: String
    let branch: String
    let changes: [GitChange]
}

struct GitSourceFile: Identifiable, Equatable, Sendable {
    let path: String
    let isStaged: Bool
    let isUnstaged: Bool
    let isUntracked: Bool
    let isConflicted: Bool
    let indexStatus: String
    let worktreeStatus: String
    var id: String { path }

    func statusLetter(isStaged: Bool) -> String {
        if isConflicted { return "U" }
        let status = isStaged ? indexStatus : worktreeStatus
        if isUntracked || status == "?" { return "U" }
        return status == " " ? "M" : status
    }
}

struct GitStash: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
}

struct GitSyncStatus: Equatable, Sendable {
    let upstream: String?
    let ahead: Int
    let behind: Int
    let remotes: [String]
}

struct GitPatchHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: String
    let patch: String
}

struct GitPartialStage: Sendable {
    let patch: String
    let hunks: [GitPatchHunk]
}

struct GitSourceSnapshot: Equatable, Sendable {
    let root: String
    let branch: String
    let head: String?
    let indexFingerprint: String
    let files: [GitSourceFile]
    let sync: GitSyncStatus
    let stashes: [GitStash]
    var stagedFiles: [GitSourceFile] { files.filter(\.isStaged) }
    var unstagedFiles: [GitSourceFile] { files.filter(\.isUnstaged) }
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
    static let mutationLock = NSLock()
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
            return GitWorktree(
                path: String(path.dropFirst(9)), branch: branch ?? "Detached HEAD",
                isLocked: fields.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }),
                isPrunable: fields.contains(where: { $0 == "prunable" || $0.hasPrefix("prunable ") }))
        }
    }

    static func validateGitPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0")
        else { throw GitFailure(message: "Invalid file path from Git status.") }
    }

    static func validateBranchName(_ name: String, at root: String) throws {
        guard !name.isEmpty, name.count <= 256,
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw GitFailure(message: "Enter a valid branch name.") }
        _ = try run(at: root, ["check-ref-format", "--branch", name])
    }

    static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    static func commit(at root: String) throws -> String {
        try run(at: root, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .newlines)
    }

    static func requireNoOperation(_ root: String) throws {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            let path = try run(at: root, ["rev-parse", "--path-format=absolute", "--git-path", marker])
                .trimmingCharacters(in: .newlines)
            if FileManager.default.fileExists(atPath: path) {
                throw GitFailure(message: "Finish the current Git operation in \(root) first.")
            }
        }
    }

    static func requireClean(_ root: String) throws {
        try requireNoOperation(root)
        guard try run(at: root, ["status", "--porcelain=v1", "--untracked-files=normal"]).isEmpty else {
            throw GitFailure(
                message: "Commit or stash local changes in \(root) before merging. Both worktrees must be clean.")
        }
    }

    static func safeFile(_ path: String, root: String) throws -> URL {
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
    static func run(
        at directory: String, _ arguments: [String], accepted: Set<Int32> = [0], timeout: TimeInterval = 30,
        input: Data? = nil
    )
        throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SparkGit-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("out"), errors = temporary.appendingPathComponent("err")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        var inputHandle: FileHandle?
        if let input {
            guard input.count <= 4_194_304 else {
                throw GitFailure(message: "The selected Git patch exceeds the 4 MB limit.")
            }
            let inputURL = temporary.appendingPathComponent("in")
            try input.write(to: inputURL, options: .atomic)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        }
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? inputHandle?.close(); try? out.close(); try? err.close() }
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
        process.standardInput = inputHandle ?? FileHandle.nullDevice
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
