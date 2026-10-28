import SwiftUI
import Foundation

struct SourceControlPanel: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var sourceControl: GitSourceControlStore
    @State private var message = ""
    @State private var generatingMessage = false
    @State private var actionError: String?
    @State private var stashToDiscard: GitStash?
    @State private var confirmsDiscardStash = false
    @State private var watchError: String?
    @State private var partialStageFile: GitSourceFile?
    @State private var showsConflictResolver = false
    @AppStorage("commitMessageProvider") private var commitMessageProvider = CommitMessageProvider.codex.rawValue

    private var messageProvider: CommitMessageProvider {
        CommitMessageProvider(rawValue: commitMessageProvider) ?? .codex
    }

    private var repositoryPath: String { session.repository?.root ?? session.directory.path }
    private var watchKey: String { "\(session.id):\(session.directory.path):\(session.repository?.root ?? "")" }
    private var subtitle: String {
        guard let snapshot = sourceControl.snapshot else { return repositoryPath }
        return "\(snapshot.branch) · \(snapshot.files.count) changed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source Control").font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    workspace.showsSourceControl = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).help("Close Source Control").accessibilityLabel("Close Source Control")
            }
            .padding(14)
            Divider().opacity(0.4)

            if let snapshot = sourceControl.snapshot {
                snapshotContent(snapshot)
            } else if let error = sourceControl.error {
                ContentUnavailableView(
                    "Unable to Read Repository", systemImage: "exclamationmark.triangle", description: Text(error)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Reading repository…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 286)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.07)))
        .task(id: watchKey) { await watchRepository() }
        .alert(
            "Source Control",
            isPresented: Binding(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .sheet(item: $partialStageFile) { file in
            PartialStageSheet(sourceControl: sourceControl, file: file)
        }
        .sheet(isPresented: $showsConflictResolver) {
            ConflictResolutionView(session: session, sourceControl: sourceControl)
        }
        .confirmationDialog("Discard Stash?", isPresented: $confirmsDiscardStash, titleVisibility: .visible) {
            Button("Discard Stash", role: .destructive) {
                guard let stash = stashToDiscard else { return }
                perform { try await sourceControl.dropStash(stash) }
                stashToDiscard = nil
            }
            Button("Cancel", role: .cancel) { stashToDiscard = nil }
        } message: {
            Text("This permanently removes the saved changes without applying them.")
        }
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: GitSourceSnapshot) -> some View {
        ScrollView {
            fileList(snapshot).padding(12)
        }
        if !snapshot.files.isEmpty {
            Divider().opacity(0.4)
            commitComposer(snapshot)
        }
    }

    @ViewBuilder
    private func fileList(_ snapshot: GitSourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            syncControls(snapshot)
            if snapshot.files.contains(where: \.isConflicted) {
                Button {
                    showsConflictResolver = true
                } label: {
                    Label("Fix Merge Conflicts with AI…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).tint(.orange)
                .disabled(sourceControl.isWorking)
                .help("Generate reviewed resolutions using the selected Git AI provider")
            }
            stashSection(snapshot)
            if !snapshot.stagedFiles.isEmpty {
                fileSection("Staged Changes", count: snapshot.stagedFiles.count) {
                    ForEach(snapshot.stagedFiles) { file in fileRow(file, isStaged: true) }
                }
            }
            if !snapshot.unstagedFiles.isEmpty {
                fileSection("Changes", count: snapshot.unstagedFiles.count) {
                    ForEach(snapshot.unstagedFiles) { file in fileRow(file, isStaged: false) }
                }
                Button("Stage All Changes") { perform { try await sourceControl.stageAll() } }
                    .disabled(sourceControl.isWorking)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            statusMessages
            if snapshot.files.isEmpty {
                ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    private func syncControls(_ snapshot: GitSourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("SYNC").font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.sync.upstream != nil {
                    HStack(spacing: 4) {
                        syncCount("arrow.up", snapshot.sync.ahead, color: .orange, label: "ahead")
                        syncCount(
                            "arrow.down", snapshot.sync.behind, color: snapshot.sync.behind > 0 ? .red : .secondary,
                            label: "behind")
                    }
                    .help(
                        "\(snapshot.sync.ahead) commits ahead and \(snapshot.sync.behind) commits behind the upstream"
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(snapshot.sync.ahead) commits ahead, \(snapshot.sync.behind) commits behind")
                }
            }
            syncActions(snapshot)
        }
    }

    private func syncActions(_ snapshot: GitSourceSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            Button {
                perform { try await sourceControl.fetch() }
            } label: {
                Text("Fetch").frame(maxWidth: .infinity)
            }
            .disabled(sourceControl.isWorking)
            middleSyncAction(snapshot)
            Button {
                perform { try await sourceControl.stashChanges() }
            } label: {
                Text("Stash").frame(maxWidth: .infinity)
            }
            .disabled(sourceControl.isWorking || snapshot.files.isEmpty)
            .help("Save staged, unstaged, and untracked changes")
            pushButton(snapshot)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 10, weight: .medium))
    }

    @ViewBuilder
    private func middleSyncAction(_ snapshot: GitSourceSnapshot) -> some View {
        if let upstream = snapshot.sync.upstream {
            Button {
                perform { try await sourceControl.pull() }
            } label: {
                Text("Pull").frame(maxWidth: .infinity)
            }
            .disabled(sourceControl.isWorking || snapshot.sync.behind == 0 || !snapshot.files.isEmpty)
            .help(snapshot.files.isEmpty ? "Fast-forward from \(upstream)" : "Stash or commit changes before pulling")
        } else {
            Button {
            } label: {
                Text("Pull").frame(maxWidth: .infinity)
            }
            .disabled(true)
            .help("Publish the branch to origin before pulling")
        }
    }

    @ViewBuilder
    private func pushButton(_ snapshot: GitSourceSnapshot) -> some View {
        if snapshot.sync.upstream == nil {
            Button {
                perform { try await sourceControl.publishBranch(to: "origin") }
            } label: {
                Text("Publish").frame(maxWidth: .infinity)
            }
            .disabled(
                sourceControl.isWorking || !snapshot.sync.remotes.contains("origin")
                    || snapshot.branch == "Detached HEAD")
            .help(
                snapshot.sync.remotes.contains("origin")
                    ? "Publish this branch to origin and set it as the upstream"
                    : "Add an origin remote before publishing this branch")
        } else {
            Button {
                perform { try await sourceControl.push() }
            } label: {
                Text("Push").frame(maxWidth: .infinity)
            }
            .disabled(snapshot.sync.ahead == 0 || sourceControl.isWorking)
            .help("Push the current branch to its upstream")
        }
    }

    private func syncCount(_ icon: String, _ count: Int, color: Color, label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text("\(count)").font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .help("\(count) commits \(label) upstream")
    }

    @ViewBuilder
    private func stashSection(_ snapshot: GitSourceSnapshot) -> some View {
        if !snapshot.stashes.isEmpty {
            fileSection("Stashes", count: snapshot.stashes.count) {
                ForEach(snapshot.stashes) { stash in
                    HStack(spacing: 8) {
                        Text(stash.message).font(.system(size: 10)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Apply") { perform { try await sourceControl.applyStash(stash) } }
                            .font(.system(size: 10, weight: .medium))
                            .disabled(sourceControl.isWorking)
                            .help("Reapply this stash and remove it from the stash list")
                        Button {
                            stashToDiscard = stash
                            confirmsDiscardStash = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .tint(.red)
                        .disabled(sourceControl.isWorking)
                        .accessibilityLabel("Discard Stash")
                        .help("Permanently remove this stash without applying it")
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func fileSection<Content: View>(
        _ title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let watchError {
            Text(watchError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if let error = sourceControl.error {
            Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
    }

    private func fileRow(_ file: GitSourceFile, isStaged: Bool) -> some View {
        HStack(spacing: 7) {
            Button {
                perform {
                    if isStaged {
                        try await sourceControl.unstage(file)
                    } else {
                        try await sourceControl.stage(file.path)
                    }
                }
            } label: {
                Image(systemName: isStaged ? "minus.circle" : "plus.circle")
                    .foregroundStyle(isStaged ? .secondary : Color(red: 1, green: 0.73, blue: 0.42))
            }
            .buttonStyle(.plain).disabled(sourceControl.isWorking)
            .help(isStaged ? "Unstage \(file.path)" : "Stage \(file.path)")
            Button {
                sourceControl.selectedReviewPath = file.path
                workspace.reviewSession = session
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    if file.isConflicted {
                        Text("Conflict").font(.system(size: 9, weight: .medium)).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Review \(file.path)")
            .contextMenu {
                Button("Open in Default App", systemImage: "arrow.up.forward.square") {
                    openFile(file.path)
                }
                Button("Reveal in Finder", systemImage: "folder") {
                    revealFile(file.path)
                }
                Button(isStaged ? "Unstage File" : "Stage File", systemImage: isStaged ? "minus.circle" : "plus.circle") {
                    perform {
                        if isStaged {
                            try await sourceControl.unstage(file)
                        } else {
                            try await sourceControl.stage(file.path)
                        }
                    }
                }
                if !isStaged, !file.isConflicted {
                    Button("Stage by Hunk…", systemImage: "text.badge.plus") { partialStageFile = file }
                }
            }
            HStack(spacing: 4) {
                if sourceControl.reviewedPaths.contains(file.path) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                        .accessibilityLabel("Reviewed")
                }
                GitStatusBadge(status: file.statusLetter(isStaged: isStaged))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
    }

    private func commitComposer(_ snapshot: GitSourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Commit message", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(4...7).frame(minHeight: 84, alignment: .topLeading)
            HStack(spacing: 8) {
                Button {
                    Task { await generateMessage() }
                } label: {
                    if generatingMessage {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .disabled(
                    snapshot.stagedFiles.isEmpty || sourceControl.isWorking || generatingMessage
                        || !CommitMessageGenerator.isAvailable(provider: messageProvider)
                )
                .help(
                    CommitMessageGenerator.isAvailable(provider: messageProvider)
                        ? "Suggest a commit message with \(messageProvider.title) from staged changes"
                        : "Install and sign in to the \(messageProvider.title) CLI")
                Spacer(minLength: 0)
                Button("Commit") {
                    perform {
                        try await sourceControl.commit(message: message); message = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    snapshot.stagedFiles.isEmpty || sourceControl.isWorking
                        || message.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || snapshot.files.contains(where: \.isConflicted))
            }
            .font(.caption)
        }
        .padding(12)
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() } catch { actionError = error.localizedDescription }
        }
    }

    private func generateMessage() async {
        guard let path = sourceControl.repositoryPath else { return }
        generatingMessage = true
        defer { generatingMessage = false }
        do {
            let diff = try await Task.detached(priority: .userInitiated) {
                try GitRepository.stagedDiff(at: path)
            }.value
            message = try await CommitMessageGenerator.generate(
                from: diff, files: sourceControl.snapshot?.stagedFiles.map(\.path) ?? [], using: messageProvider)
        } catch { actionError = error.localizedDescription }
    }

    private func openFile(_ path: String) {
        guard let root = session.repository?.root else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(path))
    }

    private func revealFile(_ path: String) {
        guard let root = session.repository?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(path)])
    }

    private func watchRepository() async {
        let path = repositoryPath
        sourceControl.selectRepository(path)
        await sourceControl.refresh()
        guard !Task.isCancelled else { return }
        let directories = await Task.detached(priority: .utility) {
            GitRepository.observationDirectories(at: path)
        }.value
        do {
            let watcher = try RepositoryWatcher(directories: directories)
            defer { watcher.stop() }
            watchError = nil
            for await _ in watcher.changes {
                guard !Task.isCancelled else { return }
                await sourceControl.refresh()
            }
        } catch { watchError = error.localizedDescription }
    }
}

private struct PartialStageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sourceControl: GitSourceControlStore
    let file: GitSourceFile
    @State private var stage: GitPartialStage?
    @State private var selectedHunks: Set<Int> = []
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stage Changes by Hunk").font(.headline)
                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            if isLoading {
                ProgressView("Reading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let stage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(stage.hunks) { hunk in
                            Toggle(isOn: selection(for: hunk)) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hunk.header).font(.system(size: 11, weight: .medium, design: .monospaced))
                                    Text(preview(hunk.patch)).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                            .padding(9)
                            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("Cannot Stage Hunks", systemImage: "text.badge.xmark", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error, stage != nil {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    guard let stage else { return }
                    isApplying = true
                    Task {
                        do {
                            try await sourceControl.stageHunks(
                                stage.hunks.filter { selectedHunks.contains($0.id) },
                                expectedPatch: stage.patch, path: file.path)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            isApplying = false
                        }
                    }
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Stage \(selectedHunks.count) Hunk\(selectedHunks.count == 1 ? "" : "s")")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(stage == nil || selectedHunks.isEmpty || isLoading || isApplying || sourceControl.isWorking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 460)
        .task {
            do {
                let result = try await sourceControl.partialStage(for: file)
                guard !Task.isCancelled else { return }
                stage = result
                selectedHunks = Set(result.hunks.map(\.id))
            } catch let failure { error = failure.localizedDescription }
            isLoading = false
        }
    }

    private func selection(for hunk: GitPatchHunk) -> Binding<Bool> {
        Binding(
            get: { selectedHunks.contains(hunk.id) },
            set: { if $0 { selectedHunks.insert(hunk.id) } else { selectedHunks.remove(hunk.id) } })
    }

    private func preview(_ patch: String) -> String {
        patch.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
            .filter { !$0.hasPrefix("+++") && !$0.hasPrefix("---") }
            .joined(separator: "\n")
    }
}
