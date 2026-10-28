import Foundation
import Combine

@MainActor
final class GitSourceControlStore: ObservableObject {
    @Published private(set) var repositoryPath: String?
    @Published private(set) var snapshot: GitSourceSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?
    @Published var reviewedPaths: Set<String> = []
    @Published var selectedReviewPath: String?

    private var refreshID = UUID()

    func selectRepository(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard repositoryPath != normalized else { return }
        repositoryPath = normalized
        snapshot = nil
        reviewedPaths.removeAll()
        selectedReviewPath = nil
        refreshID = UUID()
    }

    func refresh() async {
        guard let path = repositoryPath else { return }
        let refreshID = UUID()
        self.refreshID = refreshID
        let result = await Task.detached(priority: .userInitiated) {
            Result { try GitRepository.sourceControl(at: path) }
        }.value
        guard self.refreshID == refreshID, repositoryPath == path else { return }
        switch result {
        case .success(let value):
            if repositoryPath != value.root {
                repositoryPath = value.root
                self.refreshID = UUID()
            }
            snapshot = value
            error = nil
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    func stage(_ filePath: String) async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.stage(filePath, at: root) }
    }

    func stageAll() async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.stageAll(at: root) }
    }

    func unstage(_ file: GitSourceFile) async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.unstage(file.path, at: root) }
    }

    func partialStage(for file: GitSourceFile) async throws -> GitPartialStage {
        guard let root = repositoryPath else { throw GitFailure(message: "No Git repository is selected.") }
        return try await Task.detached(priority: .userInitiated) {
            try GitRepository.partialStage(at: root, path: file.path)
        }.value
    }

    func stageHunks(_ hunks: [GitPatchHunk], expectedPatch: String, path: String) async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) {
            try GitRepository.stageHunks(hunks, expectedPatch: expectedPatch, path: path, at: root)
        }
    }

    func commit(message: String) async throws {
        guard let root = repositoryPath, let snapshot else { return }
        try await perform(at: root) { try GitRepository.commit(at: root, message: message, expected: snapshot) }
    }

    func stashChanges() async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.stashChanges(at: root) }
    }

    func applyStash(_ stash: GitStash) async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.popStash(stash.id, at: root) }
    }

    func dropStash(_ stash: GitStash) async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.dropStash(stash.id, at: root) }
    }

    func fetch() async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.fetch(at: root) }
    }

    func pull() async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.pull(at: root) }
    }

    func push() async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.push(at: root) }
    }

    func publishBranch(to remote: String) async throws {
        guard let root = repositoryPath else { return }
        try await perform(at: root) { try GitRepository.publishBranch(to: remote, at: root) }
    }

    private func perform(at path: String, operation: @escaping @Sendable () throws -> Void) async throws {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let updated = try await Task.detached(priority: .userInitiated) {
            try operation()
            return try GitRepository.sourceControl(at: path)
        }.value
        guard repositoryPath == path else { return }
        snapshot = updated
        error = nil
    }
}
