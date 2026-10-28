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

    func commit(message: String) async throws {
        guard let root = repositoryPath, let snapshot else { return }
        try await perform(at: root) { try GitRepository.commit(at: root, message: message, expected: snapshot) }
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
