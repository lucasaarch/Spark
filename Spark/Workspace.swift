import AppKit
import Combine

@MainActor
final class Workspace: ObservableObject {
    let id: UUID
    @Published var name: String { didSet { changed() } }
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published var selectedID: UUID? { didSet { changed() } }
    @Published var showsSettings = false
    @Published var showsCommandPalette = false
    @Published var showsActivity = false
    @Published var worktreeSession: TerminalSession?
    @Published var reviewSession: TerminalSession?
    @Published var actionError: String?
    @Published private(set) var conversations: [AgentConversation] = []
    @Published var focusMode = false { didSet { changed() } }
    weak var window: NSWindow?
    var lastWindowFrame: String?
    var onChange: (() -> Void)?
    var onAgentChange: ((TerminalSession, AgentActivity?) -> Void)?
    var onSessionRemoved: ((UUID) -> Void)?
    var onLastTerminalExit: (() -> Void)?
    private var observations: [UUID: Set<AnyCancellable>] = [:]
    private var stopping = false

    init(snapshot: WorkspaceSnapshot? = nil, name: String = "Workspace") {
        id = snapshot?.id ?? UUID()
        self.name = AgentMetrics.clean(snapshot?.name ?? name) ?? "Workspace"
        guard let snapshot, snapshot.isValid else { return }
        tabs = snapshot.tabs
        selectedID = snapshot.selectedID ?? tabs.first?.activePaneID
        focusMode = snapshot.focusMode
        lastWindowFrame = snapshot.windowFrame
        conversations = snapshot.conversations ?? []
        for record in snapshot.sessions {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: record.directory, isDirectory: &isDirectory)
            let directory =
                exists && isDirectory.boolValue
                ? URL(fileURLWithPath: record.directory) : FileManager.default.homeDirectoryForCurrentUser
            let session = TerminalSession(id: record.id, directory: directory, worktree: record.worktree)
            session.customTitle = AgentMetrics.clean(record.customTitle)
            session.conversation = record.conversation
            register(session)
        }
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }
    var selectedTab: WorkspaceTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.layout.sessionIDs.contains(selectedID) }
    }
    var visibleSessionIDs: [UUID] { selectedTab?.layout.sessionIDs ?? [] }
    var canSplit: Bool { selected != nil && visibleSessionIDs.count < 8 }
    var hasActiveCommands: Bool { sessions.contains(where: \.hasActiveCommand) }

    func showReview(for source: TerminalSession? = nil) {
        guard let source = source ?? selected else { return }
        Task {
            await source.refreshRepository()
            guard sessions.contains(where: { $0 === source }) else { return }
            reviewSession = source
        }
    }

    func showWorktreeCreator(for source: TerminalSession? = nil) {
        guard let source = source ?? selected else { return }
        Task {
            await source.refreshRepository()
            guard sessions.contains(where: { $0 === source }) else { return }
            guard source.repository != nil else {
                actionError = "This terminal is not inside a Git repository."; return
            }
            worktreeSession = source
        }
    }

    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id, name: name, tabs: tabs,
            sessions: sessions.map {
                .init(
                    id: $0.id, directory: $0.directory.path, customTitle: $0.customTitle,
                    conversation: $0.conversation, worktree: $0.worktree)
            },
            selectedID: selectedID, focusMode: focusMode,
            windowFrame: window.flatMap {
                $0.styleMask.contains(.fullScreen) ? lastWindowFrame : NSStringFromRect($0.frame)
            } ?? lastWindowFrame,
            conversations: conversations)
    }

    @discardableResult
    func add(directory: URL? = nil, worktree: WorktreeRecord? = nil, launch: AgentLaunch? = nil) -> TerminalSession {
        let session = TerminalSession(
            directory: directory ?? selected?.directory ?? FileManager.default.homeDirectoryForCurrentUser,
            worktree: worktree ?? (directory == nil ? selected?.worktree : nil), launch: launch)
        register(session)
        tabs.append(WorkspaceTab(layout: .pane(session.id), activePaneID: session.id))
        select(session)
        changed()
        return session
    }

    func canApply(_ preset: PanePreset) -> Bool {
        selected != nil && visibleSessionIDs.count - 1 + preset.extraCount <= 8
    }

    @discardableResult
    func split(
        _ axis: SplitAxis, source: TerminalSession? = nil, directory: URL? = nil,
        worktree: WorktreeRecord? = nil, launch: AgentLaunch? = nil
    ) -> TerminalSession? {
        guard let selected = source ?? selected,
            let index = tabs.firstIndex(where: { $0.layout.sessionIDs.contains(selected.id) }),
            tabs[index].layout.sessionIDs.count < 8
        else { return nil }
        let session = TerminalSession(
            directory: directory ?? selected.directory, worktree: worktree ?? selected.worktree, launch: launch)
        register(session)
        tabs[index].layout = tabs[index].layout.splitting(selected.id, with: session.id, axis: axis)
        select(session)
        changed()
        return session
    }

    @discardableResult
    func apply(_ preset: PanePreset) -> Bool {
        guard canApply(preset), let current = selected,
            let tabIndex = tabs.firstIndex(where: { $0.layout.sessionIDs.contains(current.id) })
        else { return false }
        let existingIDs = tabs[tabIndex].layout.sessionIDs
        let reusedIDs = existingIDs.filter { $0 != current.id }.prefix(preset.extraCount)
        let retainedIDs = Set([current.id] + reusedIDs)
        let obsolete = sessions.filter { existingIDs.contains($0.id) && !retainedIDs.contains($0.id) }
        if obsolete.contains(where: { $0.terminal.process.running }) && !Self.confirmClose() { return false }

        let extras = (0..<(preset.extraCount - reusedIDs.count)).map { _ in
            let session = TerminalSession(directory: current.directory, worktree: current.worktree)
            register(session)
            return session
        }
        let extraIDs = Array(reusedIDs) + extras.map(\.id)
        tabs[tabIndex].layout = preset.makeLayout(current: current.id, extras: extraIDs)
        tabs[tabIndex].activePaneID = extraIDs[0]
        for session in obsolete { discard(session) }
        selectedID = extraIDs[0]
        changed()
        return true
    }

    func select(_ session: TerminalSession) {
        guard let index = tabs.firstIndex(where: { $0.layout.sessionIDs.contains(session.id) }) else { return }
        if tabs[index].activePaneID != session.id { tabs[index].activePaneID = session.id }
        if selectedID != session.id { selectedID = session.id }
    }

    func selectTab(_ tab: WorkspaceTab) {
        if let session = sessions.first(where: { $0.id == tab.activePaneID }) { select(session) }
    }

    func selectNext(_ offset: Int) {
        guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedTab?.id }) else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }

    func selectNextPane() {
        let ids = visibleSessionIDs
        guard let selectedID, let index = ids.firstIndex(of: selectedID),
            let session = sessions.first(where: { $0.id == ids[(index + 1) % ids.count] })
        else { return }
        select(session)
    }

    func setRatio(_ ratio: Double, splitID: UUID) {
        guard ratio.isFinite else { return }
        for index in tabs.indices {
            let updated = tabs[index].layout.settingRatio(ratio, for: splitID)
            if updated != tabs[index].layout { tabs[index].layout = updated; changed(); return }
        }
    }

    func close(_ session: TerminalSession) {
        if session.hasActiveCommand && !Self.confirmClose() { return }
        remove(session)
    }

    func closeTab(_ tab: WorkspaceTab) {
        let targets = sessions.filter { tab.layout.sessionIDs.contains($0.id) }
        if targets.contains(where: \.hasActiveCommand) && !Self.confirmClose() { return }
        targets.forEach { remove($0) }
    }

    func remove(_ session: TerminalSession, exitedNaturally: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.layout.sessionIDs.contains(session.id) }) else { return }
        let wasSelected = selectedID == session.id
        let precedingPaneID = tabs[index].layout.sessionIDs.prefix(while: { $0 != session.id }).last
        if let layout = tabs[index].layout.removing(session.id) {
            tabs[index].layout = layout
            if tabs[index].activePaneID == session.id {
                tabs[index].activePaneID = precedingPaneID ?? layout.sessionIDs[0]
            }
        } else {
            tabs.remove(at: index)
        }
        discard(session)
        if wasSelected { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].activePaneID }
        changed()
        if sessions.isEmpty {
            if exitedNaturally && tabs.isEmpty { onLastTerminalExit?() }
            window?.performClose(nil)
        }
    }

    private func discard(_ session: TerminalSession) {
        observations.removeValue(forKey: session.id)
        session.terminal.onFocus = nil
        session.onExit = nil
        session.stop()
        sessions.removeAll { $0.id == session.id }
        onSessionRemoved?(session.id)
    }

    func stopAll() {
        stopping = true
        observations.removeAll()
        for session in sessions {
            session.terminal.onFocus = nil
            session.onExit = nil
            session.stop()
            onSessionRemoved?(session.id)
        }
        sessions.removeAll()
        tabs.removeAll()
        selectedID = nil
        stopping = false
    }

    private func register(_ session: TerminalSession) {
        sessions.append(session)
        session.terminal.onFocus = { [weak self, weak session] in
            guard let session else { return }; self?.select(session)
        }
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.remove(session, exitedNaturally: true)
        }
        var subscriptions = Set<AnyCancellable>()
        session.$directory.dropFirst().sink { [weak self] _ in self?.scheduleChange() }.store(in: &subscriptions)
        session.$customTitle.dropFirst().sink { [weak self] _ in self?.scheduleChange() }.store(in: &subscriptions)
        session.$conversation.sink { [weak self] conversation in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let conversation {
                    self.conversations.removeAll { $0.id == conversation.id && $0.provider == conversation.provider }
                    self.conversations.insert(conversation, at: 0)
                    self.conversations = Array(self.conversations.prefix(100))
                }
                self.changed()
            }
        }.store(in: &subscriptions)
        session.$agent.dropFirst().sink { [weak self, weak session] activity in
            guard let self, let session else { return }
            self.objectWillChange.send()
            self.onAgentChange?(session, activity)
        }.store(in: &subscriptions)
        observations[session.id] = subscriptions
    }

    private func scheduleChange() {
        DispatchQueue.main.async { [weak self] in self?.changed() }
    }

    func resume(_ conversation: AgentConversation) {
        // An already running conversation is navigated to, never launched twice.
        if let existing = sessions.first(where: {
            $0.conversation?.id == conversation.id && ($0.agent != nil || $0.hasPendingLaunch)
        }) {
            select(existing)
            window?.makeFirstResponder(existing.terminal)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: conversation.directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            actionError = "The conversation folder no longer exists: \(conversation.directory)"
            return
        }
        let session = add(
            directory: URL(fileURLWithPath: conversation.directory), worktree: conversation.worktree,
            launch: AgentLaunch(provider: conversation.provider, conversationID: conversation.id))
        session.conversation = conversation
        session.customTitle = conversation.title
        changed()
    }
    private func changed() { if !stopping { onChange?() } }

    static func confirmClose() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close terminals running commands?"
        alert.informativeText = "Running commands will be terminated. Idle terminal shells close without confirmation."
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
