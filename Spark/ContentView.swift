import SwiftUI

private let ember = Color(red: 1, green: 0.73, blue: 0.42)
private let canvas = Color(red: 0.055, green: 0.063, blue: 0.078)

struct ContentView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.focusMode {
                header
                tabs
            }
            if let session = workspace.selected {
                SessionView(session: session, workspace: workspace)
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
            SettingsView(workspace: workspace)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(ember)
                .shadow(color: ember.opacity(0.3), radius: 14)
            Text("Spark").font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("A little more possible.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
            Spacer()
            Text("LOCAL").font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5).foregroundStyle(.secondary)
            Circle().fill(Color(red: 0.58, green: 0.79, blue: 0.64)).frame(width: 5, height: 5)
            Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 16).padding(.horizontal, 8)
            tool("folder.badge.plus", "Open folder…", action: workspace.openDirectory)
            tool("arrow.up.left.and.arrow.down.right", "Focus mode · ⇧⌘F") { workspace.focusMode = true }
            tool("slider.horizontal.3", "Settings · ⌘,") { workspace.showsSettings = true }
        }
        .padding(.horizontal, 22).frame(height: 62)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(workspace.sessions) { session in
                        SessionTab(session: session, selected: workspace.selectedID == session.id,
                                   select: { workspace.select(session) }, close: { workspace.close(session) })
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
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: session.agent?.icon ?? "terminal")
                        .foregroundStyle(session.agent?.color ?? (selected ? ember : .secondary))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).lineLimit(1).truncationMode(.middle)
                        if let agent = session.agent {
                            Text("\(agent.provider.name) · \(agent.label)")
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(agent.color).lineLimit(1)
                        }
                    }.frame(maxWidth: 180, alignment: .leading)
                }.padding(.vertical, 10).padding(.leading, 12)
            }.buttonStyle(.plain).accessibilityLabel("Select \(session.title)\(session.agent.map { ", \($0.provider.name), \($0.label)" } ?? "")")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 22, height: 24)
            }.buttonStyle(ChromeButtonStyle()).help("Close tab").accessibilityLabel("Close \(session.title)")
                .padding(.trailing, 5)
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .background(session.agent?.color.opacity(selected ? 0.12 : 0.055)
                    ?? .white.opacity(selected ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(session.agent?.color.opacity(selected ? 0.5 : 0.22)
                    ?? (selected ? ember.opacity(0.25) : .white.opacity(0.04))))
        .help(session.agent.map { "\($0.provider.name) · \($0.label)" } ?? session.title)
    }
}

private struct SessionView: View {
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
                } else {
                    Text(URL(fileURLWithPath: session.shell).lastPathComponent)
                    Text("/ login").foregroundStyle(.tertiary)
                }
                if workspace.focusMode {
                    Button { workspace.focusMode = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(.plain).help("Leave focus mode · ⇧⌘F").accessibilityLabel("Leave focus mode")
                }
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).frame(height: 39)
            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            TerminalHost(workspace: workspace).padding(14)
            if session.status != .running && session.status != .ready {
                HStack {
                    Text(session.status.label).foregroundStyle(.secondary)
                    Spacer()
                    Button("New Session") { workspace.add(directory: session.directory) }
                }.font(.system(size: 12)).padding(14)
            }
        }
        .background(canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.20), radius: 16, y: 6)
        .padding(.horizontal, workspace.focusMode ? 8 : 16)
        .padding(.top, workspace.focusMode ? 8 : 0)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(session.agent?.color ?? (session.status == .running ? Color.green.opacity(0.7) : ember))
                    .frame(width: 5, height: 5)
                Text(session.agent.map { "\($0.provider.name) · \($0.label)" } ?? session.status.label)
                Text("·").foregroundStyle(.quaternary)
                Text(session.dimensions).monospacedDigit()
                Spacer()
                Text("New tab  ⌘T").padding(.trailing, 14)
                Text("Find  ⌘F")
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 22).frame(height: 34)
        }
    }

    private var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.directory.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private struct TerminalHost: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    final class Coordinator {
        var selectedID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        // Keep view identity stable across tab switches. Hiding a view preserves
        // its PTY, scrollback, selection, and renderer.
        let liveViews = workspace.sessions.map(\.terminal)
        for view in container.subviews where !liveViews.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        for session in workspace.sessions {
            let terminal = session.terminal
            if terminal.superview !== container {
                terminal.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(terminal)
                NSLayoutConstraint.activate([
                    terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    terminal.topAnchor.constraint(equalTo: container.topAnchor),
                    terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
            }
            terminal.isHidden = session.id != workspace.selectedID
        }
        guard context.coordinator.selectedID != workspace.selectedID,
              let session = workspace.selected else { return }
        context.coordinator.selectedID = session.id
        DispatchQueue.main.async { [weak workspace] in
            guard workspace?.selectedID == session.id, session.terminal.window != nil else { return }
            session.applyPreferences()
            session.start()
            session.terminal.window?.makeFirstResponder(session.terminal)
        }
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
