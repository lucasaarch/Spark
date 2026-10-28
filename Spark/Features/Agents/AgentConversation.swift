import Foundation

/// A reference to CLI-owned history, never a copy of prompts or credentials.
struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: AgentActivity.Provider
    var title: String
    let directory: String
    var worktree: WorktreeRecord?

    var isValid: Bool {
        title.count <= 160 && directory.hasPrefix("/") && directory.count <= 4096
            && (worktree?.isValid ?? true)
    }
}

struct AgentLaunch: Sendable {
    let provider: AgentActivity.Provider
    var conversationID: UUID?
}

struct WorktreeRecord: Codable, Equatable, Sendable {
    let repository: String
    let path: String
    let branch: String
    let baseCommit: String
    var baseBranch: String?

    var isValid: Bool {
        repository.hasPrefix("/") && path.hasPrefix("/") && repository.count <= 4096 && path.count <= 4096
            && branch.count <= 256 && (baseBranch?.count ?? 0) <= 256 && [40, 64].contains(baseCommit.count)
            && baseCommit.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

enum CodexConversationLocator {
    /// Codex's title renderer currently truncates this UUID at 32 characters.
    /// Only accept a long UUID prefix; never guess by cwd, mtime or latest file.
    static func prefix(from text: String) -> String? {
        let prefix = text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").lowercased()
        guard (28...36).contains(prefix.count) else { return nil }
        for (index, character) in prefix.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if character != "-" { return nil }
            } else if !character.isASCII || !character.isHexDigit {
                return nil
            }
        }
        return prefix
    }

    static func resolve(_ prefix: String, home: URL) -> UUID? {
        guard Self.prefix(from: prefix) == prefix else { return nil }
        if let complete = UUID(uuidString: prefix) { return complete }
        let folder = home.appendingPathComponent("sessions", isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return nil }
        var matches = Set<UUID>()
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            guard count <= 50_000 else { return nil }
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants(); continue
            }
            guard file.pathExtension == "jsonl", file.lastPathComponent.hasPrefix("rollout-") else { continue }
            let suffix = String(file.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
            if suffix.hasPrefix(prefix), let id = UUID(uuidString: suffix) { matches.insert(id) }
            if matches.count > 1 { return nil }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
