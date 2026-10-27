import SwiftTerm
import Testing
@testable import Spark

struct AgentNotificationTests {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private func activity(_ fields: String) throws -> AgentActivity {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]7501;app=codex:\(fields)\u{7}")
        return try #require(AgentActivity(records: terminal.programStatusRecords))
    }

    @Test func completionRequiresWorkAndDoesNotRepeatAtIdle() throws {
        var policy = AgentNotificationPolicy()
        #expect(policy.update(try activity("state=idle"), isViewing: false) == nil)
        #expect(policy.update(try activity("state=done"), isViewing: false) == nil)
        #expect(policy.update(try activity("state=working"), isViewing: false) == nil)
        #expect(policy.update(try activity("state=done"), isViewing: false) == "Finished working")
        #expect(policy.update(try activity("state=idle"), isViewing: false) == nil)
        #expect(policy.update(try activity("state=working"), isViewing: false) == nil)
        #expect(policy.update(try activity("state=idle"), isViewing: false) == "Finished working")
    }

    @Test func attentionDeduplicatesProgressAndWatchingConsumesTheTransition() throws {
        var policy = AgentNotificationPolicy()
        #expect(policy.update(try activity("state=blocked:kind=permission"), isViewing: true) == nil)
        #expect(policy.update(try activity("state=blocked:kind=permission:progress=50"), isViewing: false) == nil)
        #expect(policy.update(try activity("state=blocked:kind=question"), isViewing: false) == "Needs an answer")
        #expect(policy.update(try activity("state=error"), isViewing: false) == "Encountered an error")
        #expect(policy.update(try activity("state=error:progress=60"), isViewing: false) == nil)
        #expect(policy.update(nil, isViewing: false) == nil)
        #expect(policy.update(try activity("state=blocked:kind=permission"), isViewing: false) == "Needs approval")
    }
}
