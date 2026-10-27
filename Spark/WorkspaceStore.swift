import Foundation
import Combine

/// Stores layouts and references to CLI-owned conversations, never their content.
@MainActor
final class WorkspaceStore: ObservableObject {
    private struct Document: Codable {
        var version = 1
        var workspaces: [WorkspaceSnapshot] = []
        var openIDs: [UUID] = []
    }
    @Published private(set) var workspaces: [WorkspaceSnapshot] = []
    @Published private(set) var errorMessage: String?
    @Published var liveWorkspaces: [Workspace] = []
    var activateSession: ((UUID, UUID) -> Void)?
    private(set) var openIDs: [UUID] = []
    var openWorkspace: ((UUID?) -> Void)?
    var createWorkspace: ((String) -> Void)?
    var renameWorkspaceRequest: ((UUID, String) -> Void)?
    var deleteWorkspaceRequest: ((UUID) -> Void)?
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?
    private var canWrite = true

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucasarch.Spark")
            .appendingPathComponent("workspaces.json")
    }

    /// A nil URL provides an isolated catalog for tests and previews.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, document.workspaces.count <= 128,
                document.workspaces.allSatisfy(\.isValid),
                Set(document.workspaces.map(\.id)).count == document.workspaces.count
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            workspaces = document.workspaces
            openIDs = Array(NSOrderedSet(array: document.openIDs).array.compactMap { $0 as? UUID })
                .filter { id in workspaces.contains { $0.id == id } }
        } catch {
            // Do not replace an unreadable or newer document with an empty one.
            canWrite = false
            errorMessage = "Saved workspaces could not be read. The original file has been preserved."
        }
    }

    func save(_ snapshot: WorkspaceSnapshot) {
        guard snapshot.isValid else {
            errorMessage = "This workspace exceeds the supported layout size and could not be saved."; return
        }
        if let index = workspaces.firstIndex(where: { $0.id == snapshot.id }) {
            guard workspaces[index] != snapshot else { return }
            workspaces[index] = snapshot
        } else {
            guard workspaces.count < 128 else { errorMessage = "The saved workspace limit has been reached."; return }
            workspaces.append(snapshot)
        }
        scheduleSave()
    }

    func setOpenIDs(_ ids: [UUID]) { openIDs = ids; scheduleSave() }

    func deleteWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        workspaces.removeAll { $0.id == id }
        openIDs.removeAll { $0 == id }
        scheduleSave()
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
            let cleanName = AgentMetrics.clean(name), cleanName.count <= 160
        else { return }
        guard workspaces[index].name != cleanName else { return }
        workspaces[index].name = cleanName
        scheduleSave()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL, canWrite else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Document(workspaces: workspaces, openIDs: openIDs))
            guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            errorMessage = nil
        } catch { errorMessage = "Workspace changes could not be saved: \(error.localizedDescription)" }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flush()
        }
    }
}
