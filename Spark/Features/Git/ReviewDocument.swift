import Foundation

struct ReviewLine: Sendable {
    enum Kind: Int, Sendable { case context, added, removed, separator }
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    let kind: Kind
}

struct ReviewDocument: Sendable {
    var lines: [ReviewLine] = []
    var message: String?
    var additions: Int { lines.filter { $0.kind == .added }.count }
    var deletions: Int { lines.filter { $0.kind == .removed }.count }

    private static let header: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        } catch {
            preconditionFailure("Invalid built-in diff header expression: \(error)")
        }
    }()

    init(patch: String) {
        var old = 0, new = 0, inHunk = false
        for raw in patch.components(separatedBy: "\n") {
            let text = raw as NSString
            if let match = Self.header.firstMatch(in: raw, range: NSRange(location: 0, length: text.length)) {
                if !lines.isEmpty {
                    lines.append(
                        ReviewLine(text: "Unchanged lines omitted", oldNumber: nil, newNumber: nil, kind: .separator))
                }
                old = Int(text.substring(with: match.range(at: 1))) ?? 0
                new = Int(text.substring(with: match.range(at: 2))) ?? 0
                inHunk = true
                continue
            }
            guard inHunk else {
                if raw.hasPrefix("Binary files ") || raw == "GIT binary patch" {
                    message = "Binary file changed. Open it in its application to inspect the contents."
                }
                continue
            }
            switch raw.first {
            case "+":
                lines.append(ReviewLine(text: String(raw.dropFirst()), oldNumber: nil, newNumber: new, kind: .added))
                new += 1
            case "-":
                lines.append(ReviewLine(text: String(raw.dropFirst()), oldNumber: old, newNumber: nil, kind: .removed))
                old += 1
            case " ":
                lines.append(ReviewLine(text: String(raw.dropFirst()), oldNumber: old, newNumber: new, kind: .context))
                old += 1; new += 1
            default: break
            }
        }
        if lines.isEmpty && message == nil {
            message = "No text changes. File permissions or staged contents may differ."
        }
    }
}

struct ReviewFileNode: Identifiable {
    let id: String
    let name: String
    var change: GitChange?
    var children: [ReviewFileNode]?

    static func tree(_ changes: [GitChange]) -> [ReviewFileNode] {
        func level(_ changes: [GitChange], prefix: String) -> [ReviewFileNode] {
            let groups = Dictionary(grouping: changes) {
                String($0.path.dropFirst(prefix.count).split(separator: "/").first ?? "")
            }
            return groups.map { name, files in
                let path = prefix + name
                if let leaf = files.first(where: { $0.path == path }) {
                    return ReviewFileNode(id: path, name: name, change: leaf)
                }
                return ReviewFileNode(id: path, name: name, children: level(files, prefix: path + "/"))
            }.sorted {
                if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return level(changes, prefix: "")
    }
}
