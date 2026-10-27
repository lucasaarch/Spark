import SwiftUI

struct PaneGitControls: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @State private var showsWorktree = false

    var body: some View {
        Group {
            if let repository = session.repository {
                Button {
                    workspace.showReview(for: session)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass").frame(width: 23, height: 24)
                }
                .buttonStyle(.plain).help("Review changes in \(repository.root) · ⇧⌘G")
                .accessibilityLabel("Review changes for \(session.displayTitle)")
                Button {
                    Task {
                        await session.refreshRepository()
                        if session.repository != nil { showsWorktree.toggle() }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.branch").frame(width: 23, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(repository.isWorktree ? Color.orange : Color.secondary)
                .help("\(repository.branch) · \(repository.root)")
                .accessibilityLabel("Worktree for \(session.displayTitle)")
                .popover(isPresented: $showsWorktree, arrowEdge: .bottom) {
                    WorktreePopover(session: session, workspace: workspace, close: { showsWorktree = false })
                }
            }
        }
    }
}

private struct WorktreePopover: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    let close: () -> Void
    @State private var busy = false
    @State private var message: String?
    @State private var mergePlan: GitMergePlan?
    @State private var confirmsMerge = false

    private var record: WorktreeRecord? {
        guard let value = session.worktree, let repo = session.repository,
            URL(fileURLWithPath: value.path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: repo.root).resolvingSymlinksInPath().path
        else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let repo = session.repository {
                HStack {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange).frame(width: 18)
                    Text(repo.branch).font(.headline).lineLimit(2)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(repo.isWorktree ? "Linked worktree" : "Main working tree").font(.caption).foregroundStyle(
                    .secondary)
                Text(repo.root).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(repo.root).textSelection(.enabled)
                Divider()
                Button {
                    close()
                    workspace.showWorktreeCreator(for: session)
                } label: {
                    actionLabel("New Worktree", icon: "plus")
                }.disabled(busy)
                if repo.isWorktree {
                    Button(action: prepareMerge) {
                        actionLabel(
                            record?.baseBranch.map { "Merge into \($0)" } ?? "Merge into Main Working Tree",
                            icon: "arrow.triangle.merge")
                    }.disabled(busy)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.root)])
                } label: {
                    actionLabel("Reveal in Finder", icon: "folder")
                }

            } else {
                Text("This terminal is no longer in a Git repository.").foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .font(.system(size: 12)).foregroundStyle(.primary)
        .buttonStyle(.plain).padding(16).frame(width: 330, alignment: .leading)
        .preferredColorScheme(.dark)
        .alert("Merge Worktree", isPresented: $confirmsMerge) {
            Button("Cancel", role: .cancel) { mergePlan = nil }
            Button("Merge") { merge() }
        } message: {
            if let plan = mergePlan {
                Text(
                    "Merge \(plan.source.branch) into \(plan.destination.branch) in:\n\(plan.destination.path)\n\nBoth working trees must be clean. The worktree and branch will be kept."
                )
            }
        }
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func prepareMerge() {
        guard let source = session.repository else { return }
        let record = record
        busy = true; message = nil
        Task {
            let result = await Task.detached {
                Result { try GitRepository.prepareMerge(source: source, record: record) }
            }.value
            busy = false
            switch result {
            case .success(let plan): mergePlan = plan; confirmsMerge = true
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func merge() {
        guard let plan = mergePlan else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try GitRepository.merge(plan) } }.value
            busy = false; mergePlan = nil
            switch result {
            case .success: message = "Merged into \(plan.destination.branch)."
            case .failure(let error): message = error.localizedDescription
            }
            await session.refreshRepository()
        }
    }
}

struct WorktreeView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var origin: GitContext?
    @State private var branch = GitRepository.suggestedName()
    @State private var provider = "shell"
    @State private var split = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("New Worktree", systemImage: "arrow.triangle.branch").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("FROM THIS TERMINAL").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(
                    .secondary)
                Text(session.displayTitle).font(.headline)
                Text(origin?.root ?? session.directory.path).font(.caption).textSelection(.enabled)
                if let origin {
                    Label(origin.branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            Text("Starts at the current commit. Local changes stay in the source folder.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Worktree name").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Worktree name", text: $branch).textFieldStyle(.roundedBorder).controlSize(.large)
                    Button {
                        branch = GitRepository.suggestedName()
                    } label: {
                        Image(systemName: "dice")
                    }
                    .help("Generate another name").accessibilityLabel("Generate another worktree name")
                }
            }.disabled(busy)
            Picker("Open with", selection: $provider) {
                Text("Terminal").tag("shell")
                ForEach(AgentActivity.Provider.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
            }.pickerStyle(.segmented).disabled(busy)
            Picker("Destination", selection: $split) {
                Text("New tab").tag(false)
                Text("Split this terminal").tag(true)
            }.pickerStyle(.segmented).disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Create Worktree", action: create).keyboardShortcut(.defaultAction)
                    .disabled(busy || origin == nil || branch.isEmpty)
            }
        }
        .padding(24).frame(width: 500)
        .interactiveDismissDisabled(busy)
        .onAppear { origin = session.repository }
    }

    private func create() {
        guard let origin else { return }
        if split,
            workspace.tabs.first(where: { $0.layout.sessionIDs.contains(session.id) })?.layout.sessionIDs.count ?? 8
                >= 8 {
            error = "This tab already has eight panes. Choose New tab instead."; return
        }
        let name = branch.trimmingCharacters(in: .whitespaces)
        busy = true; error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try GitRepository.createWorktree(at: origin.root, branch: name, expected: origin) }
            }.value
            busy = false
            switch result {
            case .success(let tree):
                let launch = AgentActivity.Provider(rawValue: provider).map { AgentLaunch(provider: $0) }
                let url = URL(fileURLWithPath: tree.path)
                if !split
                    || workspace.split(.vertical, source: session, directory: url, worktree: tree, launch: launch)
                        == nil {
                    workspace.add(directory: url, worktree: tree, launch: launch)
                }
                dismiss()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
