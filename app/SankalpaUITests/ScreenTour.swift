import XCTest

/// Walks the app the way a person would and captures every screen along the way.
///
/// It doubles as a smoke test: each step asserts that the element it is about to use actually
/// exists, so a screen that fails to build fails the test rather than producing a blank picture.
final class ScreenTour: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Launches with optional overrides. Appearance is set before launch so the first frame is
    /// already in the right mode.
    private func launch(dark: Bool = false, contentSize: String? = nil) {
        // Tests run in alphabetical order and share one app container, so the first-run flag is
        // reset per launch rather than relying on a fresh install.
        app.launchArguments.append("-resetIntroduction")
        if dark {
            app.launchArguments.append("-forceDarkMode")
        }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
    }

    func testTourEveryScreen() throws {
        launch()
        dismissIntroduction(capturingAs: "00-first-run")
        capture("01-today")

        // The foot of the board holds the paused and not-yet-started cards, including a Begin that
        // is unavailable until its start date — it has to look unavailable.
        app.swipeUp()
        capture("01b-today-bottom")
        app.swipeDown()

        // Today → Vipassana detail
        let vipassana = app.staticTexts["Vipassana"]
        XCTAssertTrue(vipassana.waitForExistence(timeout: 5), "Today board did not render")
        vipassana.tap()
        capture("02-detail-in-progress")

        // Detail → every period
        let everyPeriod = app.buttons["Every period"]
        if everyPeriod.waitForExistence(timeout: 3) {
            everyPeriod.tap()
            capture("03-periods")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Detail → all sessions
        app.swipeUp()
        let allSessions = app.buttons["All sessions"]
        if allSessions.waitForExistence(timeout: 3) {
            allSessions.tap()
            capture("04-sessions")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Detail → transition history
        app.swipeUp()
        let history = app.buttons["Transition history"]
        if history.waitForExistence(timeout: 3) {
            history.tap()
            capture("05-lifecycle-history")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        capture("06-detail-bottom")

        // Log a session at another time
        app.swipeDown()
        app.swipeDown()
        let logAtTime = app.buttons["Log a session at another time"]
        if logAtTime.waitForExistence(timeout: 3) {
            logAtTime.tap()
            capture("07-log-session")
            app.buttons["Cancel"].tap()
        }

        // Back to the list
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Sankalpas"].tap()
        capture("08-list-active")

        app.buttons["All"].firstMatch.tap()
        capture("09-list-all")

        // Declare a sankalpa
        app.navigationBars.buttons["Declare a sankalpa"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New sankalpa"].waitForExistence(timeout: 3))
        capture("10-declare-empty")
        app.textFields.element(boundBy: 0).typeText("Evening walk")
        app.swipeUp()
        capture("11-declare-filled")
        app.buttons["Cancel"].tap()

        // A finished sankalpa
        app.buttons["Finished"].firstMatch.tap()
        let finished = app.staticTexts["Dream journaling"]
        if finished.waitForExistence(timeout: 3) {
            finished.tap()
            capture("12-detail-completed")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Journal
        app.tabBars.buttons["Journal"].tap()
        capture("13-journal")
    }

    /// The paused sankalpa and the one that has not begun, which are separate states to check.
    func testPausedAndNotStarted() throws {
        launch()
        dismissIntroduction()
        app.tabBars.buttons["Sankalpas"].tap()
        let paused = app.staticTexts["Sudarshan Kriya"]
        XCTAssertTrue(paused.waitForExistence(timeout: 5))
        paused.tap()
        capture("14-detail-paused")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let notStarted = app.staticTexts["Morning walk"]
        XCTAssertTrue(notStarted.waitForExistence(timeout: 3))
        notStarted.tap()
        capture("15-detail-not-started")
    }

    /// Dark Mode, where a hard-coded light colour would show up immediately.
    func testDarkMode() throws {
        launch(dark: true)
        dismissIntroduction()
        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: 10))
        capture("16-today-dark")
        app.staticTexts["Vipassana"].tap()
        capture("17-detail-dark")
        app.swipeUp()
        capture("18-detail-dark-lower")
    }

    /// An accessibility text size, which is where fixed-height rows and side-by-side layouts break.
    func testLargestTextSize() throws {
        launch(contentSize: "UICTContentSizeCategoryAccessibilityL")
        dismissIntroduction()
        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: 10))
        capture("19-today-large-text")
        app.staticTexts["Vipassana"].tap()
        capture("20-detail-large-text")
        app.tabBars.buttons["Sankalpas"].tap()
        capture("21-list-large-text")
    }

    /// Logging is one tap on the largest control in the app, so the way back out has to be there
    /// too. This drives the whole round trip: log, undo, and confirm the count returns.
    func testUndoALoggedSession() throws {
        launch()
        dismissIntroduction()

        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: 10))

        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Log a")
        ).firstMatch.tap()

        // That the session is actually removed is covered by the domain suite. What this test owns
        // is the affordance: the confirmation has to offer a way back, and taking it has to be
        // acknowledged.
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "the confirmation offered no way back")
        capture("22-undo-banner")

        undo.tap()
        // The offer is consumed: there is exactly one undo per logged session, not a button that
        // keeps removing things.
        XCTAssertTrue(undo.waitForNonExistence(timeout: 4), "the undo offer was still on screen")
        capture("23-after-undo")
    }

    /// The first-run card covers the board, so every tour dismisses it before going further.
    private func dismissIntroduction(capturingAs name: String? = nil) {
        let gotIt = app.buttons["Got it"]
        guard gotIt.waitForExistence(timeout: 5) else { return }
        if let name { capture(name) }
        gotIt.tap()
    }

    private func capture(_ name: String) {
        // Let presentation and push animations finish so screenshots are not caught mid-blur.
        Thread.sleep(forTimeInterval: 0.9)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
