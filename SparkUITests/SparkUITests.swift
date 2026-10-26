import XCTest

final class SparkUITests: XCTestCase {
    @MainActor
    func testTabsFocusSettingsAndRealShell() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["newTab"].waitForExistence(timeout: 10))
        app.typeText("printf 'SPARK_UI_%s\\n' PROOF\n")
        let output = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'SPARK_UI_PROOF'"), object: app.textViews["Terminal"])
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Exited · 0'")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        app.typeText("exit\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Exited · 0'")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
    }
}
