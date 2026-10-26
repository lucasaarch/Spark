import AppKit
import Combine

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var showsSettings = false
    @Published var focusMode = false
    weak var window: NSWindow?

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }
    var hasRunningSessions: Bool { sessions.contains { $0.terminal.process.running } }

    @discardableResult
    func add(directory: URL? = nil) -> TerminalSession {
        let session = TerminalSession(directory: directory ?? selected?.directory ?? FileManager.default.homeDirectoryForCurrentUser)
        sessions.append(session)
        selectedID = session.id
        return session
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
    }

    func selectNext(_ offset: Int) {
        guard !sessions.isEmpty, let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = sessions[(index + offset + sessions.count) % sessions.count].id
    }

    func close(_ session: TerminalSession) {
        if session.terminal.process.running && !Self.confirmClose() { return }
        remove(session)
        if sessions.isEmpty { window?.performClose(nil) }
    }

    /// Removal is separate from UI confirmation so lifetime and selection invariants are testable.
    func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.stop()
        sessions.remove(at: index)
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }

    func stopAll() {
        for session in sessions { session.stop() }
        sessions.removeAll()
        selectedID = nil
    }

    static func confirmClose() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close active terminal sessions?"
        alert.informativeText = "The shells and their running commands will be terminated. Any unsaved work in those commands may be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Sessions")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func openDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.add(directory: url)
        }
    }

    func changeFontSize(by amount: Double) {
        let current = UserDefaults.standard.double(forKey: "fontSize")
        UserDefaults.standard.set(min(28, max(11, (current == 0 ? 14 : current) + amount)), forKey: "fontSize")
        applyPreferences()
    }

    func applyPreferences() { sessions.forEach { $0.applyPreferences() } }
}
