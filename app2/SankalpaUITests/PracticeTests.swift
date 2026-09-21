import XCTest

@MainActor final class PracticeTests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(demo: Bool = false, large: Bool = false, dark: Bool = false) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["PRACTICE_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["-reset-test-store"]
        if demo { app.launchArguments.append("-demo") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if dark { app.launchArguments.append("-dark") }
        app.launch()
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 10))
    }
    private func relaunch() {
        app.terminate()
        app.launchArguments.removeAll { $0 == "-reset-test-store" || $0 == "-demo" }
        app.launch()
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 10))
    }
    private func reveal(_ element: XCUIElement, up: Bool = true) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if up { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reach \(element)")
    }
    private func tap(_ id: String, up: Bool = true) {
        let button = app.buttons[id]
        reveal(button, up: up)
        button.tap()
    }
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8) // Finish sheet/push animation before visual review.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func sessionCount() -> Int {
        let value = app.descendants(matching: .any).matching(identifier: "session-total").firstMatch
        reveal(value)
        return Int(value.value as? String ?? value.label) ?? -1
    }
    func testDeclareBeginRecordUndoAndRelaunch() {
        launch()
        capture("01-welcome")
        app.buttons["declare-intention"].tap()
        let title = app.textFields["intention-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Reading with attention")
        capture("02-declaration")
        app.buttons["save-intention"].tap()
        let item = app.buttons["open-Reading with attention"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        tap("begin-practice")
        tap("begin-today-start")
        tap("confirm-begin")
        tap("record-now")
        XCTAssertTrue(app.buttons["undo-session"].waitForExistence(timeout: 5))
        app.buttons["undo-session"].tap()
        XCTAssertEqual(sessionCount(), 0)
        tap("record-now", up: false)
        XCTAssertEqual(sessionCount(), 1)
        capture("03-recorded")
        relaunch()
        XCTAssertTrue(app.buttons["open-Reading with attention"].waitForExistence(timeout: 5))
        app.buttons["open-Reading with attention"].tap()
        XCTAssertEqual(sessionCount(), 1)
        app.buttons["Journal"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Reading with attention"].waitForExistence(timeout: 5))
        capture("04-journal")
    }
    func testBackfillWhilePausedAndAfterStopping() {
        launch(demo: true)
        app.buttons["open-Morning stillness"].tap()
        let initial = sessionCount()
        tap("pause-practice")
        tap("log-past", up: false)
        XCTAssertTrue(app.buttons["save-session"].waitForExistence(timeout: 5))
        app.buttons["save-session"].tap()
        XCTAssertEqual(sessionCount(), initial + 1)
        tap("stop-practice")
        app.buttons["confirm-stop"].firstMatch.tap()
        tap("log-past", up: false)
        app.buttons["save-session"].tap()
        XCTAssertEqual(sessionCount(), initial + 2)
        capture("05-terminal-backfill")
        relaunch()
        app.buttons["Collection"].firstMatch.tap()
        app.buttons["Finished"].tap()
        let item = app.buttons["collection-Morning stillness"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        XCTAssertEqual(sessionCount(), initial + 2)
    }
    func testClearStaysEmptyAndOldHistoryRemainsReachable() {
        launch(demo: true)
        app.buttons["Collection"].firstMatch.tap()
        app.buttons["Finished"].tap()
        tap("collection-An earlier chapter")
        tap("all-sessions")
        XCTAssertTrue(app.navigationBars["Practice history"].waitForExistence(timeout: 5))
        capture("06-old-history")
        app.buttons["Today"].firstMatch.tap()
        app.buttons["Your data"].tap()
        tap("clear-data")
        app.buttons["Clear everything"].tap()
        relaunch()
        XCTAssertTrue(app.staticTexts["Your first sankalpa"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["open-Morning stillness"].exists)
    }
    func testFutureIntentionCanBeStoppedBeforeStart() {
        launch(demo: true)
        app.buttons["Collection"].firstMatch.tap()
        tap("collection-A future intention")
        XCTAssertFalse(app.buttons["begin-practice"].isEnabled)
        tap("stop-practice")
        app.buttons["confirm-stop"].firstMatch.tap()
        let stopped = app.descendants(matching: .any).matching(identifier: "status-stopped").firstMatch
        reveal(stopped, up: false)
        XCTAssertTrue(stopped.waitForExistence(timeout: 5))
        capture("21-future-stopped")
    }
    func testStandardAndDarkScreens() {
        launch(demo: true)
        capture("07-today")
        app.buttons["open-Morning stillness"].tap()
        capture("08-detail")
        tap("log-past")
        capture("09-backfill-form")
        app.buttons["Cancel"].tap()
        tap("Explore period history")
        capture("10-period-history")
        app.buttons["Collection"].firstMatch.tap()
        capture("11-collection")
        app.buttons["Journal"].firstMatch.tap()
        capture("12-journal")
        app.terminate(); app.launchArguments.removeAll { $0 == "-reset-test-store" }; app.launchArguments += ["-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["open-Morning stillness"].waitForExistence(timeout: 5))
        capture("13-dark-today")
        app.buttons["open-Morning stillness"].tap()
        capture("14-dark-detail")
    }
    func testUnreadableStoreShowsRecoveryInsteadOfAnEmptyApp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["PRACTICE_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["-corrupt-test-store"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your data needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Export original file"].exists)
        XCTAssertTrue(app.buttons["Recover from a backup"].exists)
        XCTAssertFalse(app.buttons["declare-intention"].exists)
        app.buttons["Try opening again"].tap()
        XCTAssertTrue(app.staticTexts["Your data needs attention"].exists)
        capture("24-recovery")
    }
    func testLandscapeLayout() {
        launch(demo: true)
        tap("open-Morning stillness")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        capture("22-landscape-detail")
        tap("record-at-time")
        XCTAssertTrue(app.buttons["save-session"].waitForExistence(timeout: 5))
        capture("23-landscape-session")
        app.buttons["Cancel"].tap()
    }
    func testLargestAccessibilitySize() {
        launch(demo: true, large: true)
        capture("15-accessibility-today")
        tap("open-Morning stillness")
        capture("16-accessibility-detail")
        tap("log-past")
        capture("17-accessibility-session")
        app.buttons["Cancel"].tap()
        app.buttons["Collection"].firstMatch.tap()
        capture("18-accessibility-collection")
        app.navigationBars.buttons["Declare an intention"].tap()
        capture("19-accessibility-declare")
        app.buttons["Cancel"].tap()
        app.buttons["Journal"].firstMatch.tap()
        capture("20-accessibility-journal")
    }
}
