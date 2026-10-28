import SwiftUI
import Foundation

struct SourceControlPanel: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var sourceControl: GitSourceControlStore
    @State private var message = ""
    @State private var generatingMessage = false
    @State private var actionError: String?
    @State private var watchError: String?
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
                Button { workspace.showsSourceControl = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close Source Control").accessibilityLabel("Close Source Control")
            }
            .padding(14)
            Divider().opacity(0.4)

            if let snapshot = sourceControl.snapshot {
                snapshotContent(snapshot)
            } else if let error = sourceControl.error {
                ContentUnavailableView(
                    "Unable to Read Repository", systemImage: "exclamationmark.triangle", description: Text(error))
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
            "Source Control", isPresented: Binding(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: GitSourceSnapshot) -> some View {
        ScrollView {
            if snapshot.files.isEmpty {
                ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle")
                    .padding(.vertical, 24)
            } else {
                fileList(snapshot).padding(12)
            }
        }
        Divider().opacity(0.4)
        commitComposer(snapshot)
    }

    @ViewBuilder
    private func fileList(_ snapshot: GitSourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    if isStaged { try await sourceControl.unstage(file) } else { try await sourceControl.stage(file.path) }
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
                Button(isStaged ? "Unstage File" : "Stage File", systemImage: isStaged ? "minus.circle" : "plus.circle") {
                    perform {
                        if isStaged {
                            try await sourceControl.unstage(file)
                        } else {
                            try await sourceControl.stage(file.path)
                        }
                    }
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
                    if generatingMessage { ProgressView().controlSize(.small) } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .disabled(snapshot.stagedFiles.isEmpty || sourceControl.isWorking || generatingMessage
                    || !CommitMessageGenerator.isAvailable(provider: messageProvider))
                .help(CommitMessageGenerator.isAvailable(provider: messageProvider)
                    ? "Suggest a commit message with \(messageProvider.title) from staged changes"
                    : "Install and sign in to the \(messageProvider.title) CLI")
                Spacer(minLength: 0)
                Button("Commit") { perform { try await sourceControl.commit(message: message); message = "" } }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot.stagedFiles.isEmpty || sourceControl.isWorking || message.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty || snapshot.files.contains(where: \.isConflicted))
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
