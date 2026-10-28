import SwiftUI

struct GitHistoryView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var commits: [GitCommit] = []
    @State private var selected: GitCommit?
    @State private var files: [GitCommitFile] = []
    @State private var selectedFile: GitCommitFile?
    @State private var rendered: RenderedReview?
    @State private var actionState: GitHistoryActionState?
    @State private var error: String?
    @State private var busy = true
    @State private var confirmation: HistoryConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commit History").font(.headline)
                    Text(
                        session.repository.map { "\(URL(fileURLWithPath: $0.root).lastPathComponent) · \($0.branch)" }
                            ?? session.directory.lastPathComponent
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                List(
                    commits,
                    selection: Binding(
                        get: { selected?.hash },
                        set: { hash in if let hash { select(commits.first { $0.hash == hash }) } })
                ) { commit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(commit.subject).lineLimit(1)
                        Text("\(commit.shortHash) · \(commit.author) · \(commit.date)").font(.caption2).foregroundStyle(
                            .secondary
                        ).lineLimit(1)
                    }.tag(commit.hash).padding(.vertical, 3)
                }.frame(width: 300).listStyle(.plain).scrollContentBackground(.hidden)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if let selected {
                        HStack {
                            Text(selected.subject).font(.headline).lineLimit(2); Spacer()
                            Button("Undo Last Commit…", systemImage: "arrow.uturn.backward") { confirmation = .undo }
                                .disabled(
                                    selected.hash != commits.first?.hash || actionState?.isClean != true
                                        || actionState?.isHeadPublished != false)
                            Button("Revert…", systemImage: "arrow.uturn.backward", role: .destructive) {
                                confirmation = .revert
                            }.disabled(
                                actionState?.isClean != true)
                        }.padding(12)
                        Divider().opacity(0.4)
                        HStack(spacing: 0) {
                            List(
                                files,
                                selection: Binding(
                                    get: { selectedFile?.path },
                                    set: { path in if let path { selectFile(files.first { $0.path == path }) } })
                            ) { file in
                                HStack {
                                    Text(file.status).foregroundStyle(.orange).frame(width: 22)
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                }.tag(file.path)
                            }.frame(width: 240).listStyle(.plain).scrollContentBackground(.hidden)
                            Divider()
                            if let rendered {
                                CodeReviewView(
                                    rendered: rendered, fileID: "history-\(selected.hash)-\(selectedFile?.path ?? "")")
                            } else {
                                ContentUnavailableView("Select a File", systemImage: "doc.text")
                            }
                        }
                    } else {
                        ContentUnavailableView("No Commits", systemImage: "clock")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8) }
        }.frame(width: 1000, height: 660).background(Color(red: 0.075, green: 0.083, blue: 0.10)).task { await load() }
            .confirmationDialog(
                confirmation?.title ?? "Confirm",
                isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                titleVisibility: .visible
            ) {
                Button(
                    confirmation?.buttonTitle ?? "Confirm",
                    role: confirmation?.destructive == true ? .destructive : .none
                ) { performAction() }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: {
                Text(confirmation?.message ?? "")
            }
    }

    private func load() async {
        guard let root = session.repository?.root else {
            busy = false; error = "This terminal is not inside a Git repository."; return
        }
        let result = await Task.detached {
            Result { (try GitRepository.commits(at: root), try GitRepository.historyActionState(at: root)) }
        }.value
        busy = false
        switch result {
        case .success(let value): commits = value.0; actionState = value.1; select(value.0.first)
        case .failure(let failure): error = failure.localizedDescription
        }
    }
    private func select(_ commit: GitCommit?) {
        selected = commit; selectedFile = nil; rendered = nil
        guard let commit, let root = session.repository?.root else { files = []; return }
        busy = true
        Task {
            let result = await Task.detached { Result { try GitRepository.commitFiles(commit, at: root) } }.value
            busy = false
            if case .success(let value) = result {
                files = value; selectFile(value.first)
            } else if case .failure(let failure) = result {
                error = failure.localizedDescription
            }
        }
    }
    private func selectFile(_ file: GitCommitFile?) {
        selectedFile = file; rendered = nil
        guard let commit = selected, let file, let root = session.repository?.root else { return }
        Task {
            let result = await Task.detached {
                Result { try GitRepository.commitPatch(commit, file: file.path, at: root) }
            }.value
            if case .success(let patch) = result {
                rendered = await ReviewRenderer.shared.render(patch: patch, path: file.path, old: nil, new: nil)
            } else if case .failure(let failure) = result {
                error = failure.localizedDescription
            }
        }
    }
    private func performAction() {
        guard let root = session.repository?.root, let head = commits.first?.hash, let commit = selected else { return }
        let action = confirmation; confirmation = nil; busy = true
        Task {
            let result = await Task.detached {
                Result {
                    if action == .undo {
                        try GitRepository.undoLastCommit(expectedHead: head, at: root)
                    } else {
                        try GitRepository.revertCommit(commit, expectedHead: head, at: root)
                    }
                }
            }.value; busy = false
            switch result {
            case .success: await load()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

private enum HistoryConfirmation: Equatable {
    case undo, revert
    var title: String { self == .undo ? "Undo Last Commit?" : "Revert Commit?" }
    var buttonTitle: String { self == .undo ? "Undo Commit" : "Revert Commit" }
    var destructive: Bool { true }
    var message: String {
        self == .undo
            ? "The latest unpublished commit will be undone and its changes returned to the index."
            : "A new commit will be created that reverses the selected commit."
    }
}
