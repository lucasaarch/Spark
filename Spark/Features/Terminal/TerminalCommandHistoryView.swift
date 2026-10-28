import SwiftUI

struct TerminalCommandHistoryView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var copiedID: UUID?

    private var matches: [TerminalCommand] {
        let entries = session.commandHistory.reversed()
        guard !query.isEmpty else { return Array(entries) }
        return entries.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Command History").font(.headline)
                    Text("Commands from this terminal session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search recent commands…", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            if matches.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No Commands Yet" : "No Matching Commands",
                    systemImage: "terminal",
                    description: Text(
                        "Commands entered in this zsh terminal appear here while the terminal session is open.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.command).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(
                                .enabled)
                            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.command, forType: .string)
                            copiedID = entry.id
                        } label: {
                            Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        }
                        .help("Copy command").accessibilityLabel("Copy command")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Text("\(matches.count) \(matches.count == 1 ? "command" : "commands")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Find in Scrollback…") { findInTerminal() }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 720, height: 520)
        .background(Color(red: 0.075, green: 0.083, blue: 0.10))
    }

    private func findInTerminal() {
        dismiss()
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        session.terminal.performTextFinderAction(item)
    }
}
