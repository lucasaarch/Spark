import SwiftUI

extension AgentActivity {
    var color: Color {
        switch state {
        case .idle: Color(red: 0.71, green: 0.65, blue: 0.91)
        case .working: Color(red: 0.48, green: 0.72, blue: 1)
        case .done: Color(red: 0.56, green: 0.83, blue: 0.64)
        case .blocked: Color(red: 1, green: 0.73, blue: 0.42)
        case .error: Color(red: 1, green: 0.52, blue: 0.57)
        }
    }
}

struct AgentBadge: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let agent = session.agent {
            Button { session.showsAgentDetails.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: agent.icon)
                    Text(agent.provider.name).fontWeight(.semibold)
                    Text("·").opacity(0.5)
                    Text(agent.label)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10))
                .foregroundStyle(agent.color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(agent.color.opacity(0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(agent.color.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(agent.provider.name), \(agent.label). Context and usage")
            .accessibilityIdentifier("agentDetails")
            .help("Agent status, context and usage")
            .popover(isPresented: $session.showsAgentDetails, arrowEdge: .bottom) {
                AgentDetails(session: session).id(session.id)
            }
        }
    }
}

private struct AgentDetails: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let agent = session.agent {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: agent.icon)
                        .font(.system(size: 20)).foregroundStyle(agent.color)
                        .frame(width: 42, height: 42)
                        .background(agent.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.provider.name).font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(agent.label).foregroundStyle(agent.color).font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                }
                if let title = agent.title { Text(verbatim: title).font(.headline) }
                if let message = agent.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
                if let progress = agent.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress), total: 100).tint(agent.color)
                        Text("Task progress · \(progress)%").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("CONTEXT & USAGE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    ForEach(AgentActivity.Command.allCases, id: \.self) { command in
                        Button { session.insertAgentCommand(command) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: command.icon).font(.system(size: 17)).frame(width: 24).foregroundStyle(agent.color)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(command.title).font(.system(size: 12, weight: .semibold))
                                    Text(command.detail(for: agent.provider))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(command.text(for: agent.provider))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .padding(12).contentShape(Rectangle())
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .disabled(!agent.acceptsCommands)
                        .accessibilityLabel("Insert \(command.text(for: agent.provider)): \(command.title)")
                        .help("Insert \(command.text(for: agent.provider)) into the current prompt")
                    }
                }
                Text(agent.acceptsCommands
                     ? "Inserts at the cursor without sending. Use an empty prompt, then press Return to view the CLI’s own figures."
                     : "Return to the agent’s prompt to use these shortcuts. Context and usage are displayed by the CLI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22).frame(width: 380).preferredColorScheme(.dark)
        }
    }
}
