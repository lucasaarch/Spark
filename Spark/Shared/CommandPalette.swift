import AppKit
import SwiftUI

@MainActor
private struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String?
    let enabled: Bool
    let run: @MainActor () -> Void

    var searchableText: String { "\(title) \(detail)".lowercased() }
}

struct CommandPalette: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore
    @State private var query = ""
    @State private var selectedIndex = 0

    private var commands: [PaletteCommand] { Self.commands(workspace: workspace, catalog: catalog) }
    private var matches: [PaletteCommand] {
        let available = commands.filter(\.enabled)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return available }
        return available.filter { Self.fuzzyMatch(query, in: $0.searchableText) }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                    .onTapGesture { dismiss() }

                VStack(spacing: 0) {
                    HStack(spacing: 11) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.73, blue: 0.42))
                        PaletteSearchField(
                            text: $query, move: moveSelection,
                            submit: runSelected, cancel: dismiss
                        )
                        .frame(height: 22)
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 25, height: 25)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close command palette")
                    }
                    .padding(.horizontal, 17).frame(height: 56)

                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                if matches.isEmpty {
                                    Text("No matching actions")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 90)
                                } else {
                                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                                        commandRow(command, index: index).id(command.id)
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: .infinity)
                        .onChange(of: selectedIndex) { _, _ in scrollToSelection(proxy) }
                        .onChange(of: matches.map(\.id)) { _, _ in
                            selectedIndex = 0
                            scrollToSelection(proxy)
                        }
                    }

                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                    HStack(spacing: 14) {
                        Text("↑↓ Navigate")
                        Text("↩ Run")
                        Spacer()
                        Text("\(matches.count) results")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 15).frame(height: 34)
                }
                .frame(
                    width: min(600, geometry.size.width - 36),
                    height: min(520, geometry.size.height - 48)
                )
                .background(
                    Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.45), radius: 36, y: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func moveSelection(_ offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = (selectedIndex + offset % matches.count + matches.count) % matches.count
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard matches.indices.contains(selectedIndex) else { return }
        proxy.scrollTo(matches[selectedIndex].id)
    }

    private func commandRow(_ command: PaletteCommand, index: Int) -> some View {
        let selected = index == min(selectedIndex, max(0, matches.count - 1))
        return Button {
            run(command)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color(red: 1, green: 0.73, blue: 0.42) : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(command.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let shortcut = command.shortcut {
                    Text(shortcut).font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).frame(height: 43)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(selected ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!command.enabled)
        .opacity(command.enabled ? 1 : 0.42)
        .accessibilityIdentifier("palette-\(command.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func runSelected() {
        guard !matches.isEmpty else { return }
        run(matches[min(selectedIndex, matches.count - 1)])
    }

    private func run(_ command: PaletteCommand) {
        guard command.enabled else { return }
        dismiss()
        command.run()
    }

    private func dismiss() {
        workspace.showsCommandPalette = false
        if let terminal = workspace.selected?.terminal {
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    private static func fuzzyMatch(_ query: String, in value: String) -> Bool {
        if value.contains(query) { return true }
        var next = query.startIndex
        for character in value where character == query[next] {
            next = query.index(after: next)
            if next == query.endIndex { return true }
        }
        return false
    }

    @MainActor
    private static func commands(workspace: Workspace, catalog: WorkspaceStore) -> [PaletteCommand] {
        var result = terminalCommands(workspace: workspace)
        result += navigationCommands(workspace: workspace, catalog: catalog)
        return result
    }

    @MainActor
    private static func terminalCommands(workspace: Workspace) -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "activity", title: "Toggle Activity", detail: "Agents and recent conversations across workspaces",
                symbol: "sidebar.right", shortcut: "⇧⌘A", enabled: true, run: { workspace.showsActivity.toggle() }),
            PaletteCommand(
                id: "source-control", title: "Source Control", detail: "Stage files and create commits",
                symbol: "point.3.connected.trianglepath.dotted", shortcut: "", enabled: workspace.selected != nil,
                run: { workspace.showsSourceControl.toggle() }),
            PaletteCommand(
                id: "worktree", title: "New Worktree…", detail: "From the focused terminal's repository",
                symbol: "arrow.triangle.branch", shortcut: "⇧⌘N", enabled: workspace.selected?.repository != nil,
                run: { workspace.showWorktreeCreator() }),
            PaletteCommand(
                id: "review", title: "Review Changes…", detail: "Changes in the focused terminal's repository",
                symbol: "doc.text.magnifyingglass", shortcut: "⇧⌘G", enabled: workspace.selected?.repository != nil,
                run: { workspace.showReview() }),
            PaletteCommand(
                id: "quick-open", title: "Quick Open…", detail: "Find a file in the focused Git repository",
                symbol: "magnifyingglass", shortcut: "⌘P", enabled: workspace.selected?.repository != nil,
                run: { workspace.showQuickOpen() }),
            PaletteCommand(
                id: "command-history", title: "Command History…", detail: "Search commands entered in this terminal",
                symbol: "clock", shortcut: nil, enabled: workspace.selected != nil,
                run: { workspace.commandHistorySession = workspace.selected }),
            PaletteCommand(
                id: "new-tab", title: "New Tab", detail: "Open a terminal in the current folder", symbol: "plus.square",
                shortcut: "⌘T", enabled: true, run: { workspace.add() }),
            PaletteCommand(
                id: "open-folder", title: "Open Folder…", detail: "Choose a folder for a new terminal",
                symbol: "folder.badge.plus", shortcut: "⌘O", enabled: true, run: { workspace.openDirectory() }),
            PaletteCommand(
                id: "split-right", title: "Split Right", detail: "Add a terminal beside this pane",
                symbol: "rectangle.split.2x1", shortcut: "⌘D", enabled: workspace.canSplit,
                run: { _ = workspace.split(.vertical) }),
            PaletteCommand(
                id: "split-below", title: "Split Below", detail: "Add a terminal below this pane",
                symbol: "rectangle.split.1x2", shortcut: "⇧⌘D", enabled: workspace.canSplit,
                run: { _ = workspace.split(.horizontal) }),
            PaletteCommand(
                id: "next-pane", title: "Next Pane", detail: "Focus the next visible terminal",
                symbol: "rectangle.inset.filled", shortcut: "⌃Tab", enabled: workspace.visibleSessionIDs.count > 1,
                run: { workspace.selectNextPane() }),
            PaletteCommand(
                id: "next-tab", title: "Next Tab", detail: "Select the next tab", symbol: "arrow.right.to.line",
                shortcut: "⇧⌘]", enabled: workspace.tabs.count > 1, run: { workspace.selectNext(1) }),
            PaletteCommand(
                id: "previous-tab", title: "Previous Tab", detail: "Select the previous tab",
                symbol: "arrow.left.to.line", shortcut: "⇧⌘[", enabled: workspace.tabs.count > 1,
                run: { workspace.selectNext(-1) }),
            PaletteCommand(
                id: "close-pane", title: "Close Pane or Tab", detail: "Close the selected terminal",
                symbol: "xmark.square", shortcut: "⌘W", enabled: workspace.selected != nil,
                run: { if let selected = workspace.selected { workspace.close(selected) } }),
            PaletteCommand(
                id: "find", title: "Find in Terminal…", detail: "Search the selected terminal's scrollback",
                symbol: "magnifyingglass", shortcut: "⌘F", enabled: workspace.selected != nil,
                run: { find(in: workspace.selected) }),
            PaletteCommand(
                id: "focus", title: workspace.focusMode ? "Leave Focus Mode" : "Enter Focus Mode",
                detail: "Show or hide the terminal chrome", symbol: "arrow.up.left.and.arrow.down.right",
                shortcut: "⇧⌘F", enabled: true, run: { workspace.focusMode.toggle() }),
            PaletteCommand(
                id: "settings", title: "Settings…", detail: "Configure Spark", symbol: "slider.horizontal.3",
                shortcut: "⌘,", enabled: true, run: { workspace.showsSettings = true })
        ]

    }

    @MainActor
    private static func navigationCommands(workspace: Workspace, catalog: WorkspaceStore) -> [PaletteCommand] {
        var result: [PaletteCommand] = []
        for tab in workspace.tabs {
            guard let session = workspace.sessions.first(where: { $0.id == tab.activePaneID }) else { continue }
            result.append(
                PaletteCommand(
                    id: "tab-\(tab.id.uuidString)", title: "Switch to \(session.displayTitle)",
                    detail: "Tab · \(session.directory.path)", symbol: "terminal", shortcut: nil, enabled: true,
                    run: { workspace.selectTab(tab) }))
        }
        for conversation in workspace.conversations {
            result.append(
                PaletteCommand(
                    id: "resume-\(conversation.provider.rawValue)-\(conversation.id)",
                    title: "Resume \(conversation.title)",
                    detail: "\(conversation.provider.name) · \(conversation.directory)",
                    symbol: "arrow.counterclockwise", shortcut: nil, enabled: true,
                    run: { workspace.resume(conversation) }))
        }
        for (index, id) in workspace.visibleSessionIDs.enumerated() {
            guard let session = workspace.sessions.first(where: { $0.id == id }), id != workspace.selectedID else {
                continue
            }
            result.append(
                PaletteCommand(
                    id: "pane-\(id.uuidString)", title: "Focus \(session.displayTitle)",
                    detail: "Pane \(index + 1) · \(session.directory.path)", symbol: "rectangle.inset.filled",
                    shortcut: nil, enabled: true, run: { workspace.select(session) }))
        }
        for saved in catalog.workspaces where saved.id != workspace.id {
            result.append(
                PaletteCommand(
                    id: "workspace-\(saved.id.uuidString)", title: "Switch to \(saved.name)",
                    detail:
                        "Workspace · \(saved.sessions.count) \(saved.sessions.count == 1 ? "terminal" : "terminals")",
                    symbol: "square.stack.3d.up", shortcut: nil, enabled: true,
                    run: { catalog.openWorkspace?(saved.id) }))
        }

        var seenFolders = Set<String>()
        let directories =
            workspace.sessions.reversed().map { $0.directory.path }
            + catalog.workspaces.reversed().flatMap { $0.sessions.reversed().map(\.directory) }
        for path in directories {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard seenFolders.insert(url.path).inserted,
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            result.append(
                PaletteCommand(
                    id: "folder-\(url.path)", title: "New Terminal · \(name)", detail: url.path, symbol: "folder",
                    shortcut: nil, enabled: true, run: { workspace.add(directory: url) }))
            if seenFolders.count == 8 { break }
        }
        return result
    }

    @MainActor
    private static func find(in session: TerminalSession?) {
        guard let session else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        session.terminal.performTextFinderAction(item)
    }
}
