import SwiftUI

/// Bundled vector language marks; unknown file types retain the native document icon.
struct ReviewFileIcon: View {
    let path: String
    let isFolder: Bool

    var body: some View {
        Group {
            if isFolder {
                Image(systemName: "folder").foregroundStyle(.orange.opacity(0.8))
            } else if let language = language {
                Image("Language-" + language.name)
                    .resizable().scaledToFit().foregroundStyle(language.color)
            } else {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private var language: (name: String, color: Color)? {
        let file = URL(fileURLWithPath: path)
        if file.lastPathComponent == "Dockerfile" { return ("docker", .cyan) }
        switch file.pathExtension.lowercased() {
        case "swift": return ("swift", .orange)
        case "ts", "mts", "cts": return ("typescript", .blue)
        case "js", "mjs", "cjs": return ("javascript", .yellow)
        case "tsx", "jsx": return ("react", .cyan)
        case "py", "pyi": return ("python", .yellow)
        case "rs": return ("rust", .orange)
        case "go": return ("go", .cyan)
        case "c", "h": return ("c", .blue)
        case "cc", "cpp", "cxx", "hpp": return ("cplusplus", .blue)
        case "kt", "kts": return ("kotlin", .purple)
        case "rb": return ("ruby", .red)
        case "php": return ("php", .purple)
        case "json", "jsonc": return ("json", .secondary)
        case "yml", "yaml": return ("yaml", .red)
        case "toml": return ("toml", .orange)
        case "css", "scss", "sass": return ("css3", .blue)
        case "html", "htm": return ("html5", .orange)
        case "md", "mdx": return ("markdown", .secondary)
        case "sh", "bash", "zsh", "fish": return ("gnubash", .green)
        default: return nil
        }
    }
}
