import SwiftUI

struct GitBranchSelector: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @State private var isPresented = false

    var body: some View {
        if let repository = session.repository {
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(repository.isWorktree ? Color.orange : Color.secondary)
                    Text(repository.branch).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9).frame(height: 26)
                .background(.white.opacity(0.045), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 170)
            .fixedSize(horizontal: true, vertical: false)
            .help("Switch Git branch · \(repository.branch)")
            .accessibilityLabel("Branch: \(repository.branch)")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                GitBranchPickerPopover(session: session, workspace: workspace, close: { isPresented = false })
            }
        }
    }
}

private struct GitBranchPickerPopover: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    let close: () -> Void
    @State private var branches: [GitBranch] = []
    @State private var query = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var branchToSwitch: GitBranch?
    @State private var showsCreateDialog = false

    private var filteredBranches: [GitBranch] {
        guard !query.isEmpty else { return branches }
        return branches.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.remote?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Branches").font(.system(size: 13, weight: .semibold))
                    Text("Switch the current working tree")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button {
                    fetchBranches()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).help("Fetch remote branches")
                .disabled(isWorking)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search branches…", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    branchSection("LOCAL", branches: filteredBranches.filter { !$0.isRemote })
                    branchSection("REMOTE", branches: filteredBranches.filter(\.isRemote))
                    if filteredBranches.isEmpty && !isWorking {
                        ContentUnavailableView(
                            query.isEmpty ? "No Branches" : "No Matching Branches",
                            systemImage: "arrow.triangle.branch"
                        )
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 180)

            if let message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange).textSelection(.enabled)
            }

            Divider().opacity(0.5)
            GitWorktreeActions(
                session: session,
                workspace: workspace,
                close: close,
                createBranch: { showsCreateDialog = true },
                isBranchActionDisabled: isWorking
            )
        }
        .padding(14).frame(width: 310, alignment: .leading)
        .preferredColorScheme(.dark)
        .task { await loadBranches() }
        .sheet(isPresented: $showsCreateDialog) {
            CreateGitBranchDialog(currentBranch: session.repository?.branch ?? "") { name in
                createBranch(name)
            }
        }
        .confirmationDialog(
            "Switch Branch?",
            isPresented: Binding(get: { branchToSwitch != nil }, set: { if !$0 { branchToSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch Branch") { switchBranch() }
            Button("Cancel", role: .cancel) { branchToSwitch = nil }
        } message: {
            Text(
                branchToSwitch.map {
                    "Switch to \($0.isRemote ? "remote branch" : "local branch") \($0.name)? This requires a clean working tree."
                } ?? "")
        }
    }

    @ViewBuilder
    private func branchSection(_ title: String, branches: [GitBranch]) -> some View {
        if !branches.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.9).foregroundStyle(.secondary)
                ForEach(branches) { branch in
                    Button {
                        guard !branch.isCurrent else { return }
                        branchToSwitch = branch
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(branch.isCurrent ? .orange : .secondary)
                                .frame(width: 14)
                            Text(branch.name).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(branch.isCurrent ? "CURRENT" : branch.isRemote ? branch.remote ?? "REMOTE" : "LOCAL")
                                .font(.system(size: 8, weight: .semibold)).tracking(0.3)
                                .foregroundStyle(branch.isRemote ? .blue : .secondary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(
                            branch.isCurrent ? .orange.opacity(0.09) : .white.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(isWorking || branch.isCurrent)
                    .help(branch.isRemote ? "Remote branch \(branch.remote ?? "")/\(branch.name)" : branch.name)
                }
            }
        }
    }

    private func loadBranches() async {
        guard let root = session.repository?.root else { return }
        let result = await Task.detached(priority: .utility) {
            Result { try GitRepository.branches(at: root) }
        }.value
        if case .success(let values) = result {
            branches = values
        } else if case .failure(let failure) = result {
            message = failure.localizedDescription
        }
    }

    private func fetchBranches() {
        guard let root = session.repository?.root else { return }
        isWorking = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try GitRepository.fetchAll(at: root); return try GitRepository.branches(at: root)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let values):
                branches = values
                await session.refreshRepository()
            case .failure(let failure): message = failure.localizedDescription
            }
        }
    }

    private func switchBranch() {
        guard let branch = branchToSwitch, let repository = session.repository else { return }
        branchToSwitch = nil
        isWorking = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try GitRepository.switchBranch(branch, in: repository)
                    return try GitRepository.branches(at: repository.root)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let values):
                branches = values
                await session.refreshRepository()
                close()
            case .failure(let failure): message = failure.localizedDescription
            }
        }
    }

    private func createBranch(_ name: String) {
        guard let repository = session.repository else { return }
        isWorking = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try GitRepository.createBranch(name, expected: repository)
                    return try GitRepository.branches(at: repository.root)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let values):
                branches = values
                await session.refreshRepository()
                close()
            case .failure(let failure): message = failure.localizedDescription
            }
        }
    }
}

private struct CreateGitBranchDialog: View {
    let currentBranch: String
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Branch").font(.title3.weight(.semibold))
                Text("Create and switch from \(currentBranch).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .focused($isNameFocused).onSubmit(submit)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 340).preferredColorScheme(.dark)
        .onAppear { isNameFocused = true }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        create(value)
        dismiss()
    }
}
