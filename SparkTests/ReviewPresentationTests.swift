import AppKit
import SwiftUI
import Testing
@testable import Spark

@MainActor
@Suite(.serialized)
struct ReviewPresentationTests {
    @Test func changingFilesResetsScrollButLiveEditsKeepReadingPosition() async throws {
        let line = String(repeating: "long code ", count: 30)
        let patch = "@@ -0,0 +1,100 @@\n" + Array(repeating: "+" + line, count: 100).joined(separator: "\n")
        let first = await ReviewRenderer.shared.render(patch: patch, path: "first.txt", old: nil, new: nil)
        let host = NSHostingView(rootView: CodeReviewView(rendered: first, fileID: "first.txt"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await settle(host)
        let scroll = try #require(codeScroll(in: host))
        #expect(scroll.contentView.bounds.origin == leadingEdge(of: scroll))
        try expectUnpaddedCodeBesideGutter(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 180, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin
        #expect(position.x > 0 && position.y > 0)
        let changed = await ReviewRenderer.shared.render(
            patch: patch + "\n+new line\n", path: "first.txt", old: nil, new: nil)
        host.rootView = CodeReviewView(rendered: changed, fileID: "first.txt")
        try await settle(host)
        #expect(scroll.contentView.bounds.origin == position)
        host.rootView = CodeReviewView(rendered: first, fileID: "second.txt")
        try await settle(host)
        #expect(scroll.contentView.bounds.origin == leadingEdge(of: scroll))
        try expectUnpaddedCodeBesideGutter(scroll)
        let short = await ReviewRenderer.shared.render(
            patch: "@@ -0,0 +1 @@\n+short\n", path: "short.txt", old: nil, new: nil)
        host.rootView = CodeReviewView(rendered: short, fileID: "short.txt")
        window.setContentSize(NSSize(width: 950, height: 450))
        try await settle(host)
        try expectUnpaddedCodeBesideGutter(scroll)
        host.rootView = CodeReviewView(rendered: first, fileID: "third.txt")
        window.setContentSize(NSSize(width: 500, height: 300))
        try await settle(host)
        try expectUnpaddedCodeBesideGutter(scroll)
        #expect(scroll.contentView.bounds.origin == .zero)
    }

    @Test func openReviewUpdatesSameStatusEditsAndKeepsSelection() async throws {
        let fixture = try GitWorkflowTests.RepositoryFixture()
        defer { fixture.remove() }
        let tracked = fixture.repository.appendingPathComponent("tracked.txt")
        let content = Array(repeating: String(repeating: "wide ", count: 50), count: 80).joined(separator: "\n")
        try (content + "\nfirst live edit\n").write(to: tracked, atomically: true, encoding: .utf8)
        let session = TerminalSession(directory: fixture.repository)
        let host = NSHostingView(rootView: ChangesView(session: session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil; session.stop() }
        try await waitForCode("first live edit", in: host)
        let scroll = try #require(codeScroll(in: host))
        #expect(scroll.contentView.bounds.origin == leadingEdge(of: scroll))
        try expectUnpaddedCodeBesideGutter(scroll)
        scroll.contentView.scroll(to: NSPoint(x: 140, y: 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin
        try (content + "\nsecond live edit\n").write(to: tracked, atomically: true, encoding: .utf8)
        try "a new file\n".write(
            to: fixture.repository.appendingPathComponent("aaa-new.ts"), atomically: true, encoding: .utf8)
        try await waitForCode("second live edit", in: host)
        #expect(codeScroll(in: host) === scroll)
        #expect(scroll.contentView.bounds.origin == position)
        // Removing the selected change must select a surviving file automatically.
        try "initial\n".write(to: tracked, atomically: true, encoding: .utf8)
        try await waitForCode("a new file", in: host)
        #expect(codeScroll(in: host)?.contentView.bounds.origin == leadingEdge(of: try #require(codeScroll(in: host))))
    }

    private func expectUnpaddedCodeBesideGutter(_ scroll: NSScrollView) throws {
        let text = try #require(scroll.documentView as? NSTextView)
        let container = try #require(scroll.superview as? ReviewCodeContainer)
        let codeStart = text.convert(text.textContainerOrigin, to: container)
        let gutterEnd = container.gutter.frame.maxX
        #expect(scroll.frame.minX == gutterEnd)
        #expect(codeStart.x == gutterEnd)
        #expect(codeStart.y == 0)
        #expect(text.textContainerInset == .zero)
        #expect(text.textContainer?.lineFragmentPadding == 0)
        #expect(scroll.verticalRulerView == nil)
    }

    private func leadingEdge(of scroll: NSScrollView) -> NSPoint {
        NSPoint(x: -scroll.contentView.contentInsets.left, y: -scroll.contentView.contentInsets.top)
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
    }

    private func codeScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        return view.subviews.lazy.compactMap { codeScroll(in: $0) }.first
    }

    private func waitForCode(_ fragment: String, in view: NSView) async throws {
        for _ in 0..<50 {
            try await settle(view)
            if let text = codeScroll(in: view)?.documentView as? NSTextView, text.string.contains(fragment) { return }
        }
        Issue.record("Live review did not display: \(fragment)")
    }
}
