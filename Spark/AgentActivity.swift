import Foundation
import SwiftTerm

/// Presentation of the CLI's own OSC 7501 reports, scoped to one PTY.
/// Titles and shell output are not reliable evidence that an agent is running.
struct AgentActivity: Equatable {
    enum Provider: Equatable {
        case codex, claude

        init?(app: String?) {
            switch app?.lowercased() {
            case "codex": self = .codex
            case "claude", "claude-code", "claude_code": self = .claude
            default: return nil
            }
        }

        var name: String { self == .codex ? "Codex" : "Claude Code" }
    }

    enum Command: CaseIterable {
        case context, usage

        var title: String { self == .context ? "Context" : "Usage" }
        var icon: String { self == .context ? "square.stack.3d.up" : "chart.bar.xaxis" }

        func text(for provider: Provider) -> String {
            switch (self, provider) {
            case (.context, .codex): "/status"
            case (.context, .claude): "/context"
            case (.usage, _): "/usage"
            }
        }

        func detail(for provider: Provider) -> String {
            switch (self, provider) {
            case (.context, .codex): "Session configuration and context usage"
            case (.context, .claude): "See what is filling the context window"
            case (.usage, .codex): "Account token activity and usage options"
            case (.usage, .claude): "Session cost, plan limits and activity"
            }
        }
    }

    let provider: Provider
    let state: TerminalProgramStatusState
    let kind: TerminalProgramStatusKind?
    let progress: Int?
    let title: String?
    let message: String?
    let acceptsCommands: Bool

    init?(records: [TerminalProgramStatus]) {
        // Both clients report a root record. A child alone must not turn the
        // containing shell (or an unrelated foreground app) into an agent UI.
        guard let root = records.first(where: { $0.id.isEmpty }),
              let provider = Provider(app: root.app) else { return nil }
        self.provider = provider
        let relevant = records.filter { Provider(app: $0.effectiveApp) == provider }
        // Surface requests for attention even when a parent is still working.
        // The latest report wins ties; SwiftTerm preserves update order.
        let report = relevant.reduce(root) { current, next in
            Self.priority(next.state) >= Self.priority(current.state) ? next : current
        }
        state = report.state
        kind = report.kind
        progress = report.progress
        title = Self.visibleText(report.title)
        message = Self.visibleText(report.message)
        acceptsCommands = (root.state == .idle || root.state == .done)
            && !relevant.contains { $0.state == .working || $0.state == .blocked || $0.state == .error }
    }

    var label: String {
        switch state {
        case .idle: "Ready"
        case .working: "Working"
        case .done: "Done"
        case .error: "Error"
        case .blocked:
            switch kind {
            case .permission: "Needs approval"
            case .question: "Needs an answer"
            case .auth: "Sign-in required"
            case nil: "Needs attention"
            }
        }
    }

    var icon: String {
        switch state {
        case .idle: "sparkles"
        case .working: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .blocked: kind == .permission ? "hand.raised.fill" : "bubble.left.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private static func priority(_ state: TerminalProgramStatusState) -> Int {
        switch state {
        case .blocked: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle: 0
        }
    }

    private static func visibleText(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.filter {
            $0.properties.generalCategory != .format && !CharacterSet.controlCharacters.contains($0)
        }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}
