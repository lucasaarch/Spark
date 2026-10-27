import XCTest

final class SparkUITests: XCTestCase {
    @MainActor
    func testActivityWorktreeAndDiffReview() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SparkUIWorkflow-" + UUID().uuidString)
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", project.path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Spark UI"])
        try git(["config", "user.email", "spark@example.invalid"])
        try "initial\n".write(to: project.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "Initial"])
        let startup = """
            [[ "$PWD" == "$HOME" ]] && cd -- '\(project.path)'
            PROMPT='%# '
            function precmd { printf '\\033]7;file://%s\\007' "$PWD"; }
            """
        try startup.write(to: folder.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["SPARK_UI_TESTING"] = "1"
        app.launchEnvironment["ZDOTDIR"] = folder.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["newTab"].waitForExistence(timeout: 10))
        app.typeText("printf 'UI_%s\\n' WORKFLOW_READY\n")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'UI_WORKFLOW_READY'"), object: app.textViews["Terminal"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Worktree for'")).firstMatch.waitForExistence(
                timeout: 10))
        app.typeKey("n", modifierFlags: [.command, .shift])
        let branch = app.textFields["Worktree name"]
        XCTAssertTrue(branch.waitForExistence(timeout: 3))
        branch.click(); branch.typeKey("a", modifierFlags: .command); branch.typeText("feature/ui-test")
        app.buttons["Create Worktree"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select '")).count, 2)
        let trees = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("project-worktrees"), includingPropertiesForKeys: nil)
        let tree = try XCTUnwrap(trees.first)
        app.typeText("printf 'UI_REVIEW_CONTENT\\n' > change.txt\n")
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: tree.path + "/change.txt") },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 5), .completed)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["change.txt"].waitForExistence(timeout: 10))
        app.staticTexts["change.txt"].click()
        let diff = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'UI_REVIEW_CONTENT'"), object: app.textViews["Code diff"])
        XCTAssertEqual(XCTWaiter.wait(for: [diff], timeout: 5), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Worktree diff review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].click()
        app.typeKey("a", modifierFlags: [.command, .shift])
        app.typeText("printf 'FOCUS_%s\\n' RETURNED\n")
        let focus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'FOCUS_RETURNED'"),
            object: app.textViews["Terminal"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 5), .completed)
    }

    @MainActor
    func testTabsFocusSettingsAndRealShell() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SPARK_UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["newTab"].waitForExistence(timeout: 10))
        app.typeText("printf 'SPARK_UI_%s\\n' PROOF\n")
        let output = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'SPARK_UI_PROOF'"), object: app.textViews["Terminal"])
        XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 5), .completed)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select '")).count, 2)
        app.typeKey("[", modifierFlags: [.command, .shift])
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Leave focus mode"].waitForExistence(timeout: 3))
        app.buttons["Leave focus mode"].click()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["Done"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select '")).count, 2)
        // Exit both login shells cleanly, then close their tabs without a confirmation.
        app.typeText("exit\n")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Exited · 0'")).firstMatch.waitForExistence(
                timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        app.typeText("exit\n")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Exited · 0'")).firstMatch.waitForExistence(
                timeout: 5))
        app.typeKey("w", modifierFlags: .command)
    }
}
