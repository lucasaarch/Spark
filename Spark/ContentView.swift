import SwiftUI

private let ember = Color(red: 1, green: 0.73, blue: 0.42)
private let canvas = Color(red: 0.055, green: 0.063, blue: 0.078)

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.focusMode {
                header
                tabs
            }
            if let message = catalog.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16)
            }
            HStack(spacing: 12) {
                WorkspaceTerminalHost(workspace: workspace)
                if workspace.showsActivity { ActivityPanel(workspace: workspace, catalog: catalog) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, workspace.focusMode ? 8 : 16)
            .padding(.top, workspace.focusMode ? 8 : 0)
            if let session = workspace.selected {
                SessionFooter(session: session, workspace: workspace, catalog: catalog)
            }
        }
        .coordinateSpace(name: "spark-content")
        .background {
            ZStack {
                VisualEffect()
                LinearGradient(
                    colors: [Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.85), canvas.opacity(0.95)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(
            isPresented: $workspace.showsSettings, onDismiss: { workspace.applyPreferences() },
            content: {
                SettingsView(workspace: workspace)
            }
        )
        .sheet(item: $workspace.worktreeSession) { session in WorktreeView(session: session, workspace: workspace) }
        .sheet(item: $workspace.reviewSession) { session in ChangesView(session: session) }
        .alert(
            "Unable to Open",
            isPresented: Binding(get: { workspace.actionError != nil }, set: { if !$0 { workspace.actionError = nil } })
        ) {
            Button("OK") { workspace.actionError = nil }
        } message: {
            Text(workspace.actionError ?? "")
        }
        .overlay {
            if workspace.showsCommandPalette {
                CommandPalette(workspace: workspace, catalog: catalog)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: workspace.showsCommandPalette)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(ember)
                .shadow(color: ember.opacity(0.3), radius: 14)
            Text("Spark").font(.system(size: 18, weight: .semibold, design: .rounded))
            Spacer()
            tool("sidebar.right", "Activity · ⇧⌘A") { workspace.showsActivity.toggle() }
            LayoutPresetMenu(workspace: workspace)
            tool("folder.badge.plus", "Open folder…", action: workspace.openDirectory)
            tool("arrow.up.left.and.arrow.down.right", "Focus mode · ⇧⌘F") { workspace.focusMode = true }
        }
        .padding(.horizontal, 22).frame(height: 62)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.tabs) { tab in
                        if let session = workspace.sessions.first(where: { $0.id == tab.activePaneID }) {
                            SessionTab(
                                session: session, selected: workspace.selectedTab?.id == tab.id,
                                paneCount: tab.layout.sessionIDs.count, tabID: tab.id,
                                paneDrag: workspace.paneDrag,
                                select: { workspace.selectTab(tab) }, close: { workspace.closeTab(tab) })
                        }
                    }
                }
            }
            tool("plus", "New tab · ⌘T") { workspace.add() }
                .accessibilityIdentifier("newTab")
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func tool(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 28, height: 28) }
            .buttonStyle(ChromeButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private struct SessionTab: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let paneCount: Int
    let tabID: UUID
    @ObservedObject var paneDrag: PaneDragState
    @State private var renaming = false
    @State private var newTitle = ""
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        tabChrome
            .help(sessionHelp)
            .contextMenu {
                Button("Rename Active Pane…") {
                    newTitle = session.customTitle ?? session.displayTitle
                    renaming = true
                }
                Button("Use Automatic Title") { session.customTitle = nil }
            }
            .sheet(isPresented: $renaming) {
                RenamePaneDialog(initialName: newTitle) { session.customTitle = $0 }
            }
    }

    private var tabChrome: some View {
        HStack(spacing: 9) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Group {
                        if let agent = session.agent {
                            Image(agent.provider == .codex ? "OpenAI" : "Anthropic")
                                .resizable().scaledToFit()
                        } else {
                            Image(systemName: "terminal")
                        }
                    }
                    .frame(width: 16, height: 16)
                    .foregroundStyle(session.agent?.color ?? (selected ? ember : .secondary))
                    Text(session.displayTitle).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                    if paneCount > 1 { Text("\(paneCount)").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .padding(.trailing, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectionLabel)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 24)
            }.buttonStyle(ChromeButtonStyle()).help("Close tab").accessibilityLabel("Close \(session.displayTitle)")
                .padding(.trailing, 5)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(height: 36)
        .background(
            session.agent?.color.opacity(selected ? 0.12 : 0.055)
                ?? .white.opacity(selected ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(
                paneDrag.tabTargetID == tabID ? ember.opacity(0.95)
                    : session.agent?.color.opacity(selected ? 0.5 : 0.22)
                        ?? (selected ? ember.opacity(0.25) : .white.opacity(0.04)),
                lineWidth: paneDrag.tabTargetID == tabID ? 2 : 1)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: paneDrag.tabTargetID)
        .background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("spark-content"))
                Color.clear
                    .onAppear { paneDrag.setTabFrame(frame, for: tabID) }
                    .onChange(of: frame) { _, newFrame in paneDrag.setTabFrame(newFrame, for: tabID) }
                    .onDisappear { paneDrag.removeTabFrame(for: tabID) }
            }
        }
    }

    private var sessionHelp: String {
        guard let agent = session.agent else { return session.displayTitle }
        return "\(agent.provider.name) · \(agent.label)"
    }

    private var selectionLabel: String {
        guard let agent = session.agent else { return "Select \(session.displayTitle)" }
        return "Select \(session.displayTitle), \(agent.provider.name), \(agent.label)"
    }
}

private struct RenamePaneDialog: View {
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String

    init(initialName: String, save: @escaping (String) -> Void) {
        self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Rename Pane").font(.title3.weight(.semibold))
                Text("Choose a name to show in the tab bar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("PANE NAME")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                TextField("Pane name", text: $name)
                    .font(.system(size: 14))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit(commit)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(AgentMetrics.clean(name) == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private func commit() {
        guard let value = AgentMetrics.clean(name) else { return }
        save(value)
        dismiss()
    }
}

struct SessionPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var paneDrag: PaneDragState

    var body: some View {
        GeometryReader { geometry in
            paneContent
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    if let preview = paneDrag.preview, preview.targetID == session.id {
                        let rect = preview.zone.rect(in: geometry.size)
                        RoundedRectangle(cornerRadius: 10)
                            .fill(ember.opacity(0.24))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(ember.opacity(0.9), lineWidth: 2)
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: paneDrag.preview)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.directory) {
            while !Task.isCancelled {
                await session.refreshRepository()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private var paneContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(ember.opacity(0.8))
                Text(shortPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                PaneGitControls(session: session, workspace: workspace)
                if session.agent != nil {
                    AgentBadge(session: session)
                }
                if workspace.visibleSessionIDs.count > 1 {
                    Button {
                        workspace.close(session)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).help("Close pane").accessibilityLabel("Close pane")
                }
                if workspace.focusMode {
                    Button {
                        workspace.focusMode = false
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.plain).help("Leave focus mode · ⇧⌘F").accessibilityLabel("Leave focus mode")
                }
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 39)
            .help("Drag this title bar to move the terminal")
            .contentShape(Rectangle()).onTapGesture {
                session.terminal.window?.makeFirstResponder(session.terminal)
                workspace.select(session)
            }
            .onDrag {
                paneDrag.begin(session.id)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: PaneDragState.contentType.identifier, visibility: .ownProcess
                ) { completion in
                    completion(Data(session.id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                Label(session.displayTitle, systemImage: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            TerminalSurface(session: session).padding(10)
            if session.status != .running && session.status != .ready {
                HStack {
                    Text(session.status.label).foregroundStyle(.secondary)
                    Spacer()
                    Button("New Session") { workspace.add(directory: session.directory) }
                }.font(.system(size: 12)).padding(14)
            }
        }
        .background(canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                workspace.selectedID == session.id ? ember.opacity(0.3) : .white.opacity(0.07))
        )
    }

    private var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.directory.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private struct SessionFooter: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceMenu(workspace: workspace, catalog: catalog)
            if workspace.visibleSessionIDs.count > 1,
                let index = workspace.visibleSessionIDs.firstIndex(of: session.id) {
                Text("Pane \(index + 1) of \(workspace.visibleSessionIDs.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Switch panes  ⌃Tab").padding(.trailing, 14)
            Text("New tab  ⌘T").padding(.trailing, 14)
            Text("Commands  ⌘K").padding(.trailing, 14)
            Text("Find  ⌘F")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 38)
    }
}

private struct LayoutPresetMenu: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        Menu {
            Section("Two panes") {
                preset(.twoColumns)
                preset(.twoRows)
            }
            Section("Three panes") {
                preset(.threeColumns)
                preset(.mainAndTwoRows)
            }
            Section("Four panes") {
                preset(.gridFour)
                preset(.mainAndThreeRows)
            }
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ChromeButtonStyle())
        .help("Split layout presets · ⌘D to split the focused pane")
        .accessibilityLabel("Split layout presets")
        .accessibilityIdentifier("paneLayouts")
    }

    private func preset(_ value: PanePreset) -> some View {
        Button {
            _ = workspace.apply(value)
        } label: {
            Text(value.name)
        }
        .disabled(!workspace.canApply(value))
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.terminal
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct WorkspaceMenu: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore
    @State private var namePrompt: WorkspaceNamePrompt?
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(ember.opacity(0.9))
                Text(workspace.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("WORKSPACES")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.1).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        isPresented = false
                        namePrompt = WorkspaceNamePrompt(kind: .create, initialName: "", workspaceID: nil)
                    } label: {
                        Label("New", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("New workspace")
                }

                if catalog.workspaces.isEmpty {
                    Text("Create a workspace to save your terminal setup.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(catalog.workspaces) { saved in workspaceRow(saved) }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            }
            .padding(12).frame(width: 310).preferredColorScheme(.dark)
        }
        .help("Saved workspaces · create, switch, rename or delete")
        .sheet(item: $namePrompt) { prompt in
            WorkspaceNameDialog(
                prompt: prompt,
                delete: prompt.workspaceID.map { id in
                    { catalog.deleteWorkspaceRequest?(id) }
                }
            ) { name in
                switch prompt.kind {
                case .create: catalog.createWorkspace?(name)
                case .rename:
                    if let id = prompt.workspaceID { catalog.renameWorkspaceRequest?(id, name) }
                }
            }
        }
        .fixedSize()
    }

    private func workspaceRow(_ saved: WorkspaceSnapshot) -> some View {
        let isCurrent = saved.id == workspace.id
        return HStack(spacing: 8) {
            Button {
                isPresented = false
                catalog.openWorkspace?(saved.id)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "square.stack.3d.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isCurrent ? ember : Color.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(saved.name).font(.system(size: 12, weight: isCurrent ? .semibold : .medium)).lineLimit(1)
                        Text("\(saved.sessions.count) \(saved.sessions.count == 1 ? "terminal" : "terminals")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if isCurrent {
                        Text("OPEN").font(.system(size: 8, weight: .bold)).tracking(0.7)
                            .foregroundStyle(ember.opacity(0.9))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open workspace \(saved.name)")

            Button {
                isPresented = false
                namePrompt = WorkspaceNamePrompt(kind: .rename, initialName: saved.name, workspaceID: saved.id)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 28)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Workspace settings")
            .accessibilityLabel("Settings for workspace \(saved.name)")

        }
        .background(isCurrent ? Color.white.opacity(0.075) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct WorkspaceNamePrompt: Identifiable {
    enum Kind: Equatable { case create, rename }
    let id = UUID()
    let kind: Kind
    let initialName: String
    let workspaceID: UUID?
    var title: String { kind == .create ? "New Workspace" : "Workspace Settings" }
    var action: String { kind == .create ? "Create" : "Save" }
}

private struct WorkspaceNameDialog: View {
    let prompt: WorkspaceNamePrompt
    let save: (String) -> Void
    let delete: (() -> Void)?
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String

    init(prompt: WorkspaceNamePrompt, delete: (() -> Void)? = nil, save: @escaping (String) -> Void) {
        self.prompt = prompt
        self.save = save
        self.delete = delete
        _name = State(initialValue: prompt.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(ember)
                Text(prompt.title).font(.title3.weight(.semibold))
            }
            TextField("Workspace name", text: $name)
                .font(.system(size: 16))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            HStack(spacing: 10) {
                if delete != nil {
                    Button("Delete Workspace", role: .destructive) { confirmsDelete = true }
                        .tint(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt.action, action: commit).keyboardShortcut(.defaultAction).disabled(
                    AgentMetrics.clean(name) == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .alert("Delete Workspace?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                dismiss()
                delete?()
            }
        } message: {
            Text("Delete “\(prompt.initialName)” and close its terminal sessions? This cannot be undone.")
        }
    }

    private func commit() {
        guard let value = AgentMetrics.clean(name) else { return }
        save(value)
        dismiss()
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(configuration.isPressed ? ember : Color.secondary)
            .background(configuration.isPressed ? .white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }
}

private struct SettingsView: View {
    @ObservedObject var workspace: Workspace
    @AppStorage("fontSize") private var fontSize = 14.0
    @AppStorage("optionAsMeta") private var optionAsMeta = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "sparkle").foregroundStyle(ember)
                Text("Make yourself at home.").font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Terminal text"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary)
                }
                Slider(value: $fontSize, in: 11...28, step: 1).tint(ember)
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: fontSize, design: .monospaced)).lineLimit(1)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(canvas, in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle("Use Option as Meta", isOn: $optionAsMeta)
            Text("Leave this off to type accented characters with your keyboard’s Option combinations.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Workspaces save automatically. Restoring opens fresh shells in the saved folders.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Spark \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 460)
        .onChange(of: fontSize) { workspace.applyPreferences() }
        .onChange(of: optionAsMeta) { workspace.applyPreferences() }
    }
}
