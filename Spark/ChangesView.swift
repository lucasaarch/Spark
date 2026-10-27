import SwiftUI

struct ChangesView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    private let origin: String
    @State private var review: GitReview?
    @State private var selection: String?
    @State private var rendered: RenderedReview?
    @State private var displayedPatch = ""
    @State private var renderedKey = ""
    @State private var error: String?
    @State private var notRepository = false
    @State private var diffError: String?
    @State private var actionError: String?
    @State private var watchError: String?
    @State private var revision = 0
    @State private var entireTask = false
    @State private var loading = true
    @State private var loadingDiff = false
    @State private var busy = false
    @State private var discardPlan: GitDiscardPlan?
    @State private var confirmsDiscard = false
    @State private var backup: URL?

    init(session: TerminalSession) {
        self.session = session
        origin = session.repository?.root ?? session.directory.path
    }

    private var selectedChange: GitChange? { review?.changes.first { $0.path == selection } }
    private var canDiscard: Bool {
        !entireTask && !busy && !loading && !loadingDiff && session.agent?.state != .working
    }
    private var hasTaskBase: Bool {
        session.worktree.map {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: origin).resolvingSymlinksInPath().path
        } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Changes").font(.headline)
                    Text(review.map { "\(URL(fileURLWithPath: $0.root).lastPathComponent) · \($0.branch)" } ?? origin)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(origin)
                }
                Spacer()
                if hasTaskBase && review != nil {
                    Picker("Comparison", selection: $entireTask) {
                        Text("Working Tree").tag(false)
                        Text("Entire Task").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 230).disabled(busy)
                }
                if loading || busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(18).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            Group {
                if let error {
                    ContentUnavailableView(
                        notRepository ? "No Git Repository" : "Unable to Load Changes",
                        systemImage: notRepository ? "folder" : "exclamationmark.triangle", description: Text(error))
                } else if loading && review == nil {
                    ProgressView("Reading repository…")
                } else if let review, review.changes.isEmpty {
                    ContentUnavailableView(
                        "No Changes", systemImage: "checkmark.circle",
                        description: Text(
                            entireTask
                                ? "No changes since this worktree was created."
                                : "There are no local changes to review."))
                } else {
                    HStack(spacing: 0) {
                        fileTree
                        Divider().opacity(0.4)
                        VStack(spacing: 0) {
                            if let selectedChange {
                                HStack {
                                    Text(selectedChange.path).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if let rendered {
                                        Text("\(rendered.document.additions) added").foregroundStyle(.green)
                                        Text("\(rendered.document.deletions) removed").foregroundStyle(.red)
                                    }
                                    if !entireTask {
                                        Button {
                                            prepareDiscard(all: false)
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward")
                                        }
                                        .disabled(!canDiscard || rendered == nil).help(
                                            "Discard local changes in this file"
                                        )
                                        .accessibilityLabel("Discard file changes")
                                    }
                                }.font(.system(size: 10)).padding(.horizontal, 14).frame(height: 38)
                                Divider().opacity(0.3)
                            }
                            ZStack {
                                if loadingDiff {
                                    ProgressView()
                                } else if let diffError {
                                    Text(diffError).foregroundStyle(.orange).padding(20).textSelection(.enabled)
                                } else if let rendered {
                                    if let message = rendered.document.message {
                                        Text(message).foregroundStyle(.secondary).padding(24)
                                    } else {
                                        CodeReviewView(rendered: rendered, fileID: renderedKey)
                                    }
                                } else {
                                    Text("Select a file to review").foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                if let review {
                    Text(
                        "\(review.changes.count) \(review.changes.count == 1 ? "file" : "files") · \(entireTask ? "Since worktree creation" : "Uncommitted changes")"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if !entireTask && !review.changes.isEmpty {
                        Button("Discard All…") { prepareDiscard(all: true) }.disabled(!canDiscard)
                    }
                }
                Spacer()
                if let watchError { Text(watchError).foregroundStyle(.orange).lineLimit(2).help(watchError) }
                if let backup {
                    Button("Show Recovery Copy") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                }
                if let review {
                    Button("Reveal Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: review.root)])
                    }
                }
            }.buttonStyle(.borderless).font(.caption).padding(14).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 1000, height: 660)
        .background(Color(red: 0.075, green: 0.083, blue: 0.10))
        .interactiveDismissDisabled(busy)
        .alert("Discard Local Changes?", isPresented: $confirmsDiscard) {
            Button("Cancel", role: .cancel) { discardPlan = nil }
            Button("Discard", role: .destructive, action: discard)
        } message: {
            if let plan = discardPlan {
                Text(
                    "\(plan.changes.count == 1 ? plan.changes[0].path : "All \(plan.changes.count) changed files")\n\nTracked files and their staged changes will be restored to HEAD. New files will be removed. A recovery copy will be saved inside this worktree's Git directory. Existing commits are kept."
                )
            }
        }
        .alert(
            "Unable to Discard",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task(id: origin) {
            let paths = await Task.detached(priority: .utility) { GitRepository.observationDirectories(at: origin) }
                .value
            guard !Task.isCancelled else { return }
            do {
                let watcher = try RepositoryWatcher(directories: paths)
                defer { watcher.stop() }
                watchError = nil
                for await _ in watcher.changes {
                    guard !Task.isCancelled else { return }
                    revision += 1
                    // Bound bursts (save/rename/index updates) without a polling timer.
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            } catch { watchError = error.localizedDescription }
        }
        .task(id: "\(revision):\(entireTask):\(selection ?? ""):\(busy):\(confirmsDiscard)") {
            guard !busy, !confirmsDiscard else { return }
            if renderedKey != "\(entireTask):\(selection ?? "")" {
                rendered = nil
                loadingDiff = selection != nil
            }
            await reload()
            if !Task.isCancelled && !busy && !confirmsDiscard { await loadDiff() }
        }
    }

    private var fileTree: some View {
        List(selection: $selection) {
            OutlineGroup(ReviewFileNode.tree(review?.changes ?? []), children: \.children) { node in
                HStack(spacing: 8) {
                    ReviewFileIcon(path: node.id, isFolder: node.children != nil)
                    Text(node.name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let change = node.change {
                        Circle().fill(
                            change.status == "D"
                                ? Color.red : change.status == "A" || change.untracked ? .green : .orange
                        ).frame(width: 5, height: 5)
                    }
                }.padding(.vertical, 4).tag(node.id).help(node.id)
            }
        }
        .listStyle(.sidebar).scrollContentBackground(.hidden).frame(width: 250)
        .background(.white.opacity(0.02))
        .disabled(busy)
    }

    private func reload() async {
        let tree = entireTask ? session.worktree : nil
        let result = await Task.detached(priority: .userInitiated) {
            Result { try GitRepository.review(at: origin, worktree: tree) }
        }.value
        guard !Task.isCancelled, !busy, !confirmsDiscard else { return }
        loading = false
        switch result {
        case .success(let value):
            if review != value { review = value }
            error = nil; notRepository = false
            if !value.changes.contains(where: { $0.path == selection }) { selection = value.changes.first?.path }
        case .failure(let failure):
            error = failure.localizedDescription; review = nil
            notRepository = (failure as? GitFailure)?.isNotRepository == true
        }
    }

    private func loadDiff() async {
        guard !loading, let review, let change = selectedChange else { rendered = nil; return }
        let key = "\(entireTask):\(change.path)"
        if renderedKey != key {
            rendered = nil; displayedPatch = ""; renderedKey = key
        }
        loadingDiff = rendered == nil
        let previousPatch = rendered == nil ? nil : displayedPatch
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(String, String?, String?)?, Error> in
            Result {
                let patch = try GitRepository.diff(change, review: review)
                if patch == previousPatch { return nil }
                let sources = GitRepository.sourceTexts(change, review: review)
                return (patch, sources.old, sources.new)
            }
        }.value
        guard !Task.isCancelled, !busy, !confirmsDiscard else { return }
        switch result {
        case .success(let value):
            diffError = nil
            guard let value else { loadingDiff = false; return }
            let valueRendered = await ReviewRenderer.shared.render(
                patch: value.0, path: change.path, old: value.1, new: value.2)
            guard !Task.isCancelled, !busy, !confirmsDiscard else { return }
            rendered = valueRendered; displayedPatch = value.0
        case .failure(let failure): diffError = failure.localizedDescription
        }
        loadingDiff = false
    }

    private func prepareDiscard(all: Bool) {
        guard canDiscard, let review else { return }
        let changes = all ? review.changes : selectedChange.map { [$0] } ?? []
        guard !changes.isEmpty else { return }
        let expectedPatch = displayedPatch
        busy = true
        Task {
            let result = await Task.detached {
                Result {
                    if !all, try GitRepository.diff(changes[0], review: review) != expectedPatch {
                        throw GitFailure(
                            message: "This file just changed. Wait for the live diff to update, then try again.")
                    }
                    return try GitRepository.prepareDiscard(review: review, changes: changes)
                }
            }.value
            busy = false
            switch result {
            case .success(let plan): discardPlan = plan; confirmsDiscard = true
            case .failure(let failure): actionError = failure.localizedDescription
            }
        }
    }

    private func discard() {
        guard let plan = discardPlan else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try GitRepository.discard(plan) } }.value
            busy = false; discardPlan = nil
            switch result {
            case .success(let url): backup = url; revision += 1
            case .failure(let failure): actionError = failure.localizedDescription
            }
        }
    }
}
