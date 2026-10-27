import SwiftUI

private let ember = Color(red: 1, green: 0.73, blue: 0.42)
private let canvas = Color(red: 0.055, green: 0.063, blue: 0.078)

struct ContentView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore
    @ObservedObject var notifications: AgentNotifications

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.focusMode {
                header
                tabs
            }
            if let message = catalog.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16)
            }
            WorkspaceTerminalHost(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, workspace.focusMode ? 8 : 16)
                .padding(.top, workspace.focusMode ? 8 : 0)
            if let session = workspace.selected {
                SessionFooter(session: session, workspace: workspace, catalog: catalog)
            }
        }
        .background {
            ZStack {
                VisualEffect()
                LinearGradient(colors: [Color(red: 0.14, green: 0.15, blue: 0.18).opacity(0.85), canvas.opacity(0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $workspace.showsSettings, onDismiss: { workspace.applyPreferences() }) {
            SettingsView(workspace: workspace, notifications: notifications)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(ember)
                .shadow(color: ember.opacity(0.3), radius: 14)
            Text("Spark").font(.system(size: 18, weight: .semibold, design: .rounded))
            Spacer()
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
                            SessionTab(session: session, selected: workspace.selectedTab?.id == tab.id,
                                       paneCount: tab.layout.sessionIDs.count,
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
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let paneCount: Int
    @State private var renaming = false
    @State private var newTitle = ""
    let select: () -> Void
    let close: () -> Void

    var body: some View {
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
                }.padding(.vertical, 10).padding(.leading, 12)
            }.buttonStyle(.plain).accessibilityLabel("Select \(session.displayTitle)\(session.agent.map { ", \($0.provider.name), \($0.label)" } ?? "")")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 24)
            }.buttonStyle(ChromeButtonStyle()).help("Close tab").accessibilityLabel("Close \(session.displayTitle)")
                .padding(.trailing, 5)
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .frame(height: 36)
        .background(session.agent?.color.opacity(selected ? 0.12 : 0.055)
                    ?? .white.opacity(selected ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(session.agent?.color.opacity(selected ? 0.5 : 0.22)
                    ?? (selected ? ember.opacity(0.25) : .white.opacity(0.04))))
        .help(session.agent.map { "\($0.provider.name) · \($0.label)" } ?? session.displayTitle)
        .contextMenu {
            Button("Rename Active Pane…") { newTitle = session.customTitle ?? ""; renaming = true }
            Button("Use Automatic Title") { session.customTitle = nil }
        }
        .alert("Rename Pane", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { session.customTitle = AgentMetrics.clean(newTitle) }
        }
    }
}

struct SessionPane: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(ember.opacity(0.8))
                Text(shortPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                if session.agent != nil {
                    AgentBadge(session: session)
                }
                if workspace.visibleSessionIDs.count > 1 {
                    Button { workspace.close(session) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Close pane").accessibilityLabel("Close pane")
                }
                if workspace.focusMode {
                    Button { workspace.focusMode = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(.plain).help("Leave focus mode · ⇧⌘F").accessibilityLabel("Leave focus mode")
                }
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 39)
            .contentShape(Rectangle()).onTapGesture {
                session.terminal.window?.makeFirstResponder(session.terminal)
                workspace.select(session)
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
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            workspace.selectedID == session.id ? ember.opacity(0.3) : .white.opacity(0.07)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Find  ⌘F")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 22).frame(height: 38)
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
        Button { _ = workspace.apply(value) } label: {
            Text(value.glyph).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(ember)
                + Text("  ") + Text(value.name)
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
    var body: some View {
        Menu {
            Button("New Workspace…") { namePrompt = WorkspaceNamePrompt(kind: .create, initialName: "") }
            Button("Rename Workspace…") { namePrompt = WorkspaceNamePrompt(kind: .rename, initialName: workspace.name) }
            Divider()
            ForEach(catalog.workspaces) { saved in
                Button { catalog.openWorkspace?(saved.id) } label: {
                    if saved.id == workspace.id { Label(saved.name, systemImage: "checkmark") }
                    else { Text(saved.name) }
                }
            }
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
        .menuStyle(.borderlessButton).fixedSize().help("Saved workspaces · create, switch or rename")
        .sheet(item: $namePrompt) { prompt in
            WorkspaceNameDialog(prompt: prompt) { name in
                switch prompt.kind {
                case .create: catalog.createWorkspace?(name)
                case .rename: workspace.name = name
                }
            }
        }
    }
}

private struct WorkspaceNamePrompt: Identifiable {
    enum Kind: Equatable { case create, rename }
    let id = UUID()
    let kind: Kind
    let initialName: String
    var title: String { kind == .create ? "New Workspace" : "Rename Workspace" }
    var action: String { kind == .create ? "Create" : "Save" }
}

private struct WorkspaceNameDialog: View {
    let prompt: WorkspaceNamePrompt
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String

    init(prompt: WorkspaceNamePrompt, save: @escaping (String) -> Void) {
        self.prompt = prompt
        self.save = save
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
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt.action, action: commit).keyboardShortcut(.defaultAction).disabled(AgentMetrics.clean(name) == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
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
    @ObservedObject var notifications: AgentNotifications
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
                HStack { Text("Terminal text"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary) }
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
            Toggle("Agent notifications", isOn: Binding(get: { notifications.enabled }, set: { notifications.setEnabled($0) }))
                .disabled(notifications.requestingAuthorization)
            Text(notifications.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
