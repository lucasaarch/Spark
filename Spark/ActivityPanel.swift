import SwiftUI

struct ActivityPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    workspace.showsActivity = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).help("Close activity · ⇧⌘A").accessibilityLabel("Close activity")
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(catalog.liveWorkspaces, id: \.id) { owner in
                        WorkspaceActivitySection(workspace: owner, catalog: catalog)
                    }
                    ForEach(
                        catalog.workspaces.filter { saved in !catalog.liveWorkspaces.contains { $0.id == saved.id } }
                    ) { saved in
                        if !(saved.conversations ?? []).isEmpty {
                            Button {
                                catalog.openWorkspace?(saved.id)
                            } label: {
                                Label(
                                    "\(saved.name) · \(saved.conversations?.count ?? 0) saved conversations",
                                    systemImage: "clock.arrow.circlepath"
                                )
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }

        }
        .frame(width: 286)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.07)))
    }
}

private struct WorkspaceActivitySection: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore
    @State private var showsHistory = true

    private var recent: [AgentConversation] {
        workspace.conversations.filter { conversation in
            !workspace.sessions.contains { $0.conversation?.id == conversation.id && $0.agent != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.name.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(
                .secondary)
            // Observe every session so a shell entering/leaving an agent updates
            // the list even when the workspace itself is in the background.
            ForEach(workspace.sessions) { session in
                ActivitySessionRow(session: session, workspace: workspace, catalog: catalog)
            }
            if workspace.sessions.allSatisfy({ $0.agent == nil }) {
                Text("No agents running").font(.caption).foregroundStyle(.tertiary)
            }
            if !recent.isEmpty {
                DisclosureGroup("Recent conversations", isExpanded: $showsHistory) {
                    ForEach(recent) { conversation in
                        Button {
                            catalog.openWorkspace?(workspace.id)
                            workspace.resume(conversation)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title).lineLimit(1)
                                    Text(conversation.provider.name)
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Resume in a new tab · \(conversation.directory)")
                    }
                }.font(.caption)
            }
        }
    }
}

private struct ActivitySessionRow: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var catalog: WorkspaceStore

    var body: some View {
        if let agent = session.agent {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    catalog.activateSession?(workspace.id, session.id)
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(agent.provider == .codex ? "OpenAI" : "Anthropic").resizable().scaledToFit()
                            .frame(width: 18, height: 18).foregroundStyle(agent.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            HStack(spacing: 5) {
                                AgentStatusIcon(agent: agent, size: 18)
                                Text(agent.label).font(.system(size: 10))
                            }.foregroundStyle(agent.color)
                            if let message = agent.message {
                                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if let branch = session.worktree?.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            }
            .padding(11)
            .background(agent.color.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(agent.color.opacity(0.16)))
        }
    }
}
