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

/// One status visual shared by Activity, the usage badge and its popover.
struct AgentStatusIcon: View {
    let agent: AgentActivity
    var size: CGFloat = 14

    var body: some View {
        Group {
            if agent.state == .working {
                WorkingOrb(color: agent.color)
            } else {
                Image(systemName: agent.icon).font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(agent.color)
        .accessibilityHidden(true)
    }
}

struct AgentBadge: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let agent = session.agent {
            Button {
                session.showsAgentDetails.toggle()
            } label: {
                HStack(spacing: 7) {
                    AgentStatusIcon(agent: agent)
                    if let remaining = session.metrics?.limitingUsage?.remainingPercent {
                        Text("\(remaining, specifier: "%.0f")% usage left").fontWeight(.semibold).monospacedDigit()
                    } else {
                        Text("Usage not reported").fontWeight(.semibold)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10))
                .foregroundStyle(agent.color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(agent.color.opacity(0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(agent.color.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(agent.provider.name), \(agent.label). \(session.metrics?.limitingUsage?.remainingPercent.map { String(format: "%.0f%% usage left", $0) } ?? "Usage not reported"). Context and usage"
            )
            .accessibilityIdentifier("agentDetails")
            .help(
                "\(agent.provider.name) · \(agent.label). \(session.metrics?.limitingUsage?.name ?? "Account usage not reported"); click for usage details."
            )
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
                    AgentStatusIcon(agent: agent, size: 28)
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
                Text("CONTEXT & USAGE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(
                    .secondary)
                if let metrics = session.metrics {
                    AgentMetricsView(metrics: metrics, provider: agent.provider, color: agent.color)
                } else {
                    Label(
                        session.hasMetricsIntegration ? "Waiting for session metrics" : "Metrics not connected",
                        systemImage: "chart.bar.xaxis"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Text(
                        session.hasMetricsIntegration
                            ? "Figures appear when the CLI reports them. Unavailable values are never treated as zero."
                            : "Open a new zsh tab in Spark and launch codex or claude to connect live metrics. "
                                + "Existing custom shell aliases and functions are preserved."
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22).frame(width: 380).preferredColorScheme(.dark)
        }
    }
}

private struct AgentMetricsView: View {
    let metrics: AgentMetrics
    let provider: AgentActivity.Provider
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("Model", metrics.model)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Context").foregroundStyle(.secondary)
                    Spacer()
                    if let percent = metrics.contextPercent {
                        Text("\(percent, specifier: "%.1f")% used").monospacedDigit()
                    } else {
                        Text("Not reported").foregroundStyle(.tertiary)
                    }
                }
                if let percent = metrics.contextPercent {
                    ProgressView(value: percent, total: 100).tint(percent >= 85 ? .orange : color)
                }
                if let window = metrics.contextWindow {
                    Text("\(window.formatted()) token window").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                tokenCard("Input tokens", metrics.inputTokens)
                tokenCard("Output tokens", metrics.outputTokens)
            }
            Text(
                provider == .claude
                    ? "Tokens in the current context, from the latest response." : "Session totals, rounded by Codex."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
            if provider == .claude {
                row("Estimated session cost", metrics.costUSD.map { String(format: "$%.4f", $0) })
            }
            if metrics.limits.isEmpty {
                row("Plan limits", nil)
            } else {
                ForEach(metrics.limits, id: \.name) { limit in
                    VStack(alignment: .leading, spacing: 6) {
                        if let detail = limit.detail {
                            row(limit.name, detail)
                        } else if let used = limit.usedPercent {
                            row(limit.name, String(format: "%.1f%% used", used))
                            ProgressView(value: used, total: 100).tint(used >= 85 ? .orange : color)
                        } else {
                            row(limit.name, limit.detail)
                        }
                        if let reset = limit.resetsAt {
                            Text("Resets \(reset, style: .relative)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text("Updated")
                Text(metrics.updatedAt, style: .time)
                Spacer()
                Text("Reported by \(provider.name)")
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }.font(.system(size: 12))
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value ?? "Not reported").multilineTextAlignment(.trailing)
                .foregroundStyle(value == nil ? .tertiary : .primary).textSelection(.enabled)
        }
    }

    private func tokenCard(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}
