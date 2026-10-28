import SwiftUI

struct ConflictResolutionView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var sourceControl: GitSourceControlStore
    @AppStorage("commitMessageProvider") private var providerValue = CommitMessageProvider.codex.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var conflicts: [GitConflictFile] = []
    @State private var resolutions: [String: String] = [:]
    @State private var selectedPath: String?
    @State private var progress: String?
    @State private var error: String?
    @State private var recoveryPath: URL?
    @State private var isLoading = true
    @State private var isGenerating = false
    @State private var isApplying = false
    @State private var confirmsDataSend = false
    @State private var confirmsApply = false

    private var provider: CommitMessageProvider { CommitMessageProvider(rawValue: providerValue) ?? .codex }
    private var selected: GitConflictFile? { conflicts.first { $0.path == selectedPath } }
    private var selectedResolution: Binding<String> {
        Binding(
            get: { selectedPath.flatMap { resolutions[$0] } ?? "" },
            set: { value in
                guard let selectedPath else { return }; resolutions[selectedPath] = value
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Resolve Merge Conflicts", systemImage: "exclamationmark.bubble").font(.headline)
                Spacer()
                if isLoading || isGenerating || isApplying { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isApplying)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONFLICTED FILES").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(
                        .secondary)
                    List(conflicts, selection: $selectedPath) { file in
                        HStack {
                            Image(systemName: resolutions[file.path] == nil ? "exclamationmark.triangle" : "sparkles")
                                .foregroundStyle(resolutions[file.path] == nil ? .red : .orange)
                            Text(file.path).lineLimit(1).truncationMode(.middle)
                        }.tag(file.path)
                    }.listStyle(.plain)
                    Button {
                        confirmsDataSend = true
                    } label: {
                        if isGenerating {
                            Label(progress ?? "Resolving…", systemImage: "sparkles")
                        } else {
                            Label("Fix Merge Conflicts", systemImage: "sparkles")
                        }
                    }.buttonStyle(.borderedProminent).disabled(
                        isLoading || isGenerating || conflicts.isEmpty
                            || !CommitMessageGenerator.isAvailable(provider: provider))
                    Text(
                        "Using \(provider.title). Text files up to 128 KB, 12 per pass. Review every proposal before applying."
                    ).font(.caption2).foregroundStyle(.secondary)
                    if !CommitMessageGenerator.isAvailable(provider: provider) {
                        Text("Install and sign in to the \(provider.title) CLI.").font(.caption2).foregroundStyle(
                            .orange)
                    }
                }.padding(12).frame(width: 260)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let selected {
                        HStack {
                            Text(selected.path).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if resolutions[selected.path] != nil {
                                Text("AI proposal · editable").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        if resolutions[selected.path] != nil {
                            TextEditor(text: selectedResolution).font(.system(size: 11, design: .monospaced))
                                .scrollContentBackground(.hidden).padding(8).background(
                                    .black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        } else if let current = selected.current {
                            ScrollView {
                                Text(current).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }.background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                            Text("Generate a proposal to inspect and edit the resolved file.").font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView(
                                "No Working File", systemImage: "doc.questionmark",
                                description: Text("This conflict must be resolved manually."))
                        }
                    } else {
                        ContentUnavailableView("No Merge Conflicts", systemImage: "checkmark.circle")
                    }
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                }
                if let recoveryPath {
                    Button("Show Recovery Copies") { NSWorkspace.shared.activateFileViewerSelecting([recoveryPath]) }
                }
                Spacer()
                Button("Apply All Resolutions…", role: .destructive) { confirmsApply = true }
                    .disabled(
                        isLoading || isGenerating || isApplying || resolutions.count != conflicts.count
                            || conflicts.isEmpty)
            }.padding(12)
        }
        .frame(width: 950, height: 620).background(Color(red: 0.075, green: 0.083, blue: 0.10))
        .task { await load() }
        .alert("Send Conflict Contents to \(provider.title)?", isPresented: $confirmsDataSend) {
            Button("Cancel", role: .cancel) {}
            Button("Generate Proposals") { generate() }
        } message: {
            Text(
                """
                The base, current, incoming, and working contents of each conflicted file will be sent to the selected AI CLI. Spark asks it to return proposed file contents only; no files are changed until you review and apply the proposals.
                """
            )
        }
        .confirmationDialog("Apply AI Resolutions?", isPresented: $confirmsApply, titleVisibility: .visible) {
            Button("Apply Resolutions", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This writes \(resolutions.count) reviewed file(s) to the working tree without staging them. Spark saves recovery copies first. Review the resulting files and stage them after Git marks the conflicts resolved."
            )
        }
    }

    private func load() async {
        guard let root = session.repository?.root else {
            isLoading = false; error = "This terminal is not inside a Git repository."; return
        }
        let result = await Task.detached { Result { try GitRepository.conflictFiles(at: root) } }.value
        isLoading = false
        switch result {
        case .success(let value): conflicts = value; selectedPath = value.first?.path
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    private func generate() {
        guard !isGenerating, let root = session.repository?.root else { return }
        isGenerating = true; error = nil; resolutions = [:]
        Task {
            do {
                let current = try await Task.detached { try GitRepository.conflictFiles(at: root) }.value
                guard !current.isEmpty else { throw GitFailure(message: "There are no conflicted files to resolve.") }
                conflicts = current
                for (index, file) in current.enumerated() {
                    progress = "Resolving \(index + 1) of \(current.count)…"
                    resolutions[file.path] = try await CommitMessageGenerator.resolve(file, using: provider)
                }
                selectedPath = current.first?.path
            } catch { self.error = error.localizedDescription }
            progress = nil; isGenerating = false
        }
    }

    private func apply() {
        guard let root = session.repository?.root else { return }
        isApplying = true; error = nil
        let proposals = resolutions
        let expected = conflicts
        Task {
            let result = await Task.detached {
                Result { try GitRepository.applyConflictResolutions(proposals, expected: expected, at: root) }
            }.value
            isApplying = false
            switch result {
            case .success(let backup):
                recoveryPath = backup
                error = "Applied to the working tree. Inspect and stage each resolved file in Source Control."
                await sourceControl.refresh()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
