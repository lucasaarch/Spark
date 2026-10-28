import SwiftUI

struct GitBranchComparisonView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [GitBranch] = []
    @State private var baseRef = ""
    @State private var targetRef = ""
    @State private var comparison: GitBranchComparison?
    @State private var selectedPath: String?
    @State private var rendered: RenderedReview?
    @State private var error: String?
    @State private var busy = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare Branches").font(.headline)
                    Text(
                        session.repository.map { "\(URL(fileURLWithPath: $0.root).lastPathComponent) · \($0.branch)" }
                            ?? session.directory.lastPathComponent
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            HStack(spacing: 10) {
                Picker("Base", selection: $baseRef) { branchOptions }
                    .labelsHidden().frame(maxWidth: .infinity)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("Compare", selection: $targetRef) { branchOptions }
                    .labelsHidden().frame(maxWidth: .infinity)
                Button("Compare") { loadComparison() }.buttonStyle(.borderedProminent).disabled(
                    busy || baseRef.isEmpty || targetRef.isEmpty || baseRef == targetRef)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            if let comparison {
                HStack(spacing: 12) {
                    Text("\(comparison.baseOnly.count) commits only in \(comparison.base.name)").foregroundStyle(
                        .secondary)
                    Text("·")
                    Text("\(comparison.targetOnly.count) commits only in \(comparison.target.name)").foregroundStyle(
                        .secondary)
                    Spacer()
                    Text("\(comparison.files.count) changed files").foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 14).padding(.vertical, 10)
                HStack(spacing: 0) {
                    List(
                        comparison.files,
                        selection: Binding(get: { selectedPath }, set: { path in if let path { select(path) } })
                    ) { file in
                        HStack {
                            GitStatusBadge(status: file.status); Text(file.path).lineLimit(1).truncationMode(.middle)
                        }.tag(file.path)
                    }.frame(width: 280).listStyle(.plain).scrollContentBackground(.hidden)
                    Divider()
                    if let rendered {
                        CodeReviewView(
                            rendered: rendered, fileID: "compare-\(baseRef)-\(targetRef)-\(selectedPath ?? "")")
                    } else {
                        ContentUnavailableView("Select a Changed File", systemImage: "doc.text")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Choose Two Branches", systemImage: "arrow.left.arrow.right",
                    description: Text("Compare file changes and commits unique to each branch."))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(10)
            }
        }.frame(width: 1000, height: 660).background(Color(red: 0.075, green: 0.083, blue: 0.10)).task {
            await loadBranches()
        }
    }

    private var branchOptions: some View {
        Group {
            ForEach(branches.filter { !$0.isRemote }) { branch in Text("\(branch.name) · Local").tag(branch.ref) }
            ForEach(branches.filter(\.isRemote)) { branch in
                Text("\(branch.name) · \(branch.remote ?? "Remote")").tag(branch.ref)
            }
        }
    }
    private func loadBranches() async {
        guard let root = session.repository?.root else {
            busy = false; error = "This terminal is not inside a Git repository."; return
        }
        let result = await Task.detached { Result { try GitRepository.branches(at: root) } }.value
        busy = false
        switch result {
        case .success(let values):
            branches = values
            baseRef = values.first(where: \.isCurrent)?.ref ?? values.first(where: { !$0.isRemote })?.ref ?? ""
            targetRef =
                values.first(where: { !$0.isRemote && $0.ref != baseRef })?.ref ?? values.first(where: {
                    $0.ref != baseRef
                })?.ref ?? ""
            if !baseRef.isEmpty && !targetRef.isEmpty { loadComparison() }
        case .failure(let failure): error = failure.localizedDescription
        }
    }
    private func loadComparison() {
        guard let root = session.repository?.root, !baseRef.isEmpty, !targetRef.isEmpty, baseRef != targetRef else {
            return
        }
        let base = baseRef
        let target = targetRef
        busy = true; error = nil; comparison = nil; rendered = nil
        Task {
            let result = await Task.detached {
                Result { try GitRepository.compareBranches(at: root, baseRef: base, targetRef: target) }
            }.value
            busy = false
            switch result {
            case .success(let value): comparison = value; if let path = value.files.first?.path { select(path) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    private func select(_ path: String) {
        guard let root = session.repository?.root else { return }
        selectedPath = path; rendered = nil; let base = baseRef, target = targetRef
        Task {
            let result = await Task.detached {
                Result { try GitRepository.compareBranchPatch(at: root, baseRef: base, targetRef: target, path: path) }
            }.value
            switch result {
            case .success(let value):
                rendered = await ReviewRenderer.shared.render(
                    patch: value.patch, path: path, old: value.baseContents, new: value.targetContents)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
