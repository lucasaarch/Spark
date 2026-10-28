import SwiftUI

struct GitWorktreeManagerView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [GitWorktreeStatus] = []
    @State private var error: String?
    @State private var busy = true
    @State private var cleanup: GitWorktreeStatus?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Worktrees", systemImage: "arrow.triangle.branch").font(.headline); Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            List(statuses) { status in
                HStack(spacing: 12) {
                    Image(systemName: status.isMain ? "house" : "arrow.triangle.branch").foregroundStyle(
                        status.isMain ? .orange : .secondary
                    ).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.worktree.branch).font(.system(size: 13, weight: .medium))
                        Text(status.worktree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Label(
                        status.isClean ? (status.isMergedIntoMain ? "Clean · Merged" : "Clean") : "Changes",
                        systemImage: status.isClean ? "checkmark.circle" : "circle.fill"
                    ).font(.caption).foregroundStyle(status.isClean ? .green : .orange)
                    Button("Open") { open(status.worktree.path) }
                    if !status.isMain {
                        Button(role: .destructive) {
                            cleanup = status
                        } label: {
                            Image(systemName: "trash")
                        }.disabled(
                            !status.isClean || !status.isMergedIntoMain || status.worktree.isLocked
                                || status.worktree.isPrunable || isOpen(status.worktree.path)
                        ).help("Remove only clean, merged worktrees")
                    }
                }.padding(.vertical, 4)
            }.listStyle(.plain)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
        }.frame(width: 760, height: 500).background(Color(red: 0.075, green: 0.083, blue: 0.10)).task { await load() }
            .confirmationDialog(
                "Remove Worktree?", isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove Worktree and Branch", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) { cleanup = nil }
            } message: {
                Text(
                    cleanup.map {
                        "\($0.worktree.path)\nThis removes the clean worktree and its branch, which is already merged into the main worktree."
                    } ?? "")
            }
    }
    private func isOpen(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return catalog.liveWorkspaces.flatMap(\.sessions).contains {
            URL(fileURLWithPath: $0.directory.path).resolvingSymlinksInPath().path == normalized
        }
    }
    private func open(_ path: String) {
        if let existing = workspace.sessions.first(where: {
            URL(fileURLWithPath: $0.directory.path).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        }) {
            workspace.select(existing)
        } else {
            workspace.add(directory: URL(fileURLWithPath: path))
        }
        dismiss()
    }
    private func load() async {
        guard let root = session.repository?.root else { busy = false; return }
        let result = await Task.detached { Result { try GitRepository.worktreeStatuses(at: root) } }.value
        busy = false
        switch result {
        case .success(let value): statuses = value
        case .failure(let failure): error = failure.localizedDescription
        }
    }
    private func remove() {
        guard let status = cleanup, let root = session.repository?.root else { return }
        cleanup = nil; busy = true
        let protected = Set(
            catalog.liveWorkspaces.flatMap(\.sessions).map {
                URL(fileURLWithPath: $0.directory.path).resolvingSymlinksInPath().path
            })
        Task {
            let result = await Task.detached {
                Result { try GitRepository.removeMergedWorktree(status, at: root, protectedPaths: protected) }
            }.value; busy = false
            switch result {
            case .success: await load()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
