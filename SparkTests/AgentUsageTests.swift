import Foundation
import Testing
@testable import Spark

struct AgentUsageTests {
    @Test(arguments: [0, 81, 100])
    func codexBadgeUsesAccountAllowanceInsteadOfEmptyContext(remaining: Int) throws {
        let title = "codex | codex | GPT-6 | codex | Context 0% used | codex | 0 in | codex | 0 out | codex | codex | weekly \(remaining)% left | codex"
        let metrics = try #require(AgentMetrics.codex(title: title))
        #expect(metrics.contextPercent == 0)
        #expect(metrics.limitingUsage?.remainingPercent == Double(remaining))
        #expect(metrics.limitingUsage?.name == "Weekly limit")
    }

    @Test func claudeUsesTheFirstAllowanceToRunOut() throws {
        let metrics = try AgentMetrics.claude(data: Data(#"{"context_window":{"used_percentage":0},"rate_limits":{"five_hour":{"used_percentage":40},"seven_day":{"used_percentage":19}}}"#.utf8))
        #expect(metrics.limitingUsage?.remainingPercent == 60)
        #expect(metrics.limitingUsage?.name == "5-hour limit")
        var weekly = metrics
        weekly.limits.reverse()
        #expect(weekly.limitingUsage == metrics.limitingUsage)
    }

    @Test(arguments: ["", "weekly unknown", "weekly 101% left", "weekly -1% left", "weekly nan% left"])
    func unavailableAccountUsageNeverFallsBackToContext(detail: String) throws {
        let title = "codex | codex | GPT-6 | codex | Context 0% used | codex | 0 in | codex | 0 out | codex | codex | \(detail) | codex"
        let metrics = try #require(AgentMetrics.codex(title: title))
        #expect(metrics.limitingUsage == nil)
    }
}
