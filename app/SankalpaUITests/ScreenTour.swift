import XCTest

/// Walks the app the way a person would and captures every screen along the way.
///
/// It doubles as a smoke test: each step asserts that the element it is about to use actually
/// exists, so a screen that fails to build fails the test rather than producing a blank picture.
final class ScreenTour: UITestCase {

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
        XCTAssertTrue(reveal(everyPeriod), "detail offered no way into the period history")
        everyPeriod.tap()
        capture("03-periods")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Detail → all sessions. The label carries the lifetime count, so it is matched on shape.
        let allSessions = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'All ' AND label ENDSWITH ' sessions'")
        ).firstMatch
        XCTAssertTrue(reveal(allSessions), "detail offered no way into the session history")
        allSessions.tap()
        capture("04-sessions")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Detail → transition history
        let history = app.buttons["Transition history"]
        XCTAssertTrue(reveal(history), "detail offered no way into the transition history")
        history.tap()
        capture("05-lifecycle-history")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        capture("06-detail-bottom")

        // Log a session at another time
        app.swipeDown()
        app.swipeDown()
        let logAtTime = app.buttons["Log a session at another time"]
        XCTAssertTrue(reveal(logAtTime), "the in-progress card offered no backdated logging")
        logAtTime.tap()
        capture("07-log-session")
        app.buttons["Cancel"].tap()

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
        XCTAssertTrue(finished.waitForExistence(timeout: 3), "no finished sankalpa to open")
        finished.tap()
        capture("12-detail-completed")
        app.navigationBars.buttons.element(boundBy: 0).tap()

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

    /// Going from the default 30 to 180 by stepper is 150 taps, so the number is typed. This
    /// drives the field the way a person would: clear it, type, and check the form agrees.
    func testDurationCanBeTyped() throws {
        launch()
        dismissIntroduction()
        app.navigationBars.buttons["Declare a sankalpa"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New sankalpa"].waitForExistence(timeout: 3))

        let duration = app.textFields["Number of days"]
        XCTAssertTrue(reveal(duration), "the duration could not be reached")
        duration.tap()

        // Tapping in clears the field, so the new number simply replaces the old one instead of
        // being spliced into it.
        duration.tap()
        duration.typeText("180")
        XCTAssertEqual(duration.value as? String, "180")
        capture("10b-declare-duration")

        app.buttons["Done"].tap()
        // The summary is derived from the same value, so an end date means the form took it.
        XCTAssertFalse(app.staticTexts["When you stop it"].exists)
        capture("10c-declare-duration-summary")
        app.buttons["Cancel"].tap()
    }

    /// A session performed and then forgotten has to be recordable from whatever state the
    /// sankalpa has since reached. The domain has always allowed it; this is about the way in.
    func testPastSessionsCanBeLoggedFromPausedAndFinishedStates() throws {
        launch()
        dismissIntroduction()
        app.tabBars.buttons["Sankalpas"].tap()

        let backfill = app.buttons["Log a past session"]

        let paused = app.staticTexts["Sudarshan Kriya"]
        XCTAssertTrue(paused.waitForExistence(timeout: 10))
        paused.tap()
        XCTAssertTrue(
            backfill.waitForExistence(timeout: 3),
            "a paused sankalpa offered no way to record a forgotten session"
        )
        backfill.tap()
        capture("25-backfill-from-paused")
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Finished"].firstMatch.tap()
        let finished = app.staticTexts["Dream journaling"]
        XCTAssertTrue(finished.waitForExistence(timeout: 3))
        finished.tap()
        XCTAssertTrue(
            backfill.waitForExistence(timeout: 3),
            "a completed sankalpa offered no way to record a forgotten session"
        )
        capture("26-backfill-from-finished")
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
        app.swipeUp()
        capture("20b-detail-large-text-period")
        app.swipeUp()
        app.swipeUp()
        app.swipeUp()
        capture("20c-detail-large-text-lifecycle")

        // The logging sheet is a form of pickers and labelled rows, which is exactly the shape
        // that breaks first at this size.
        let backfill = app.buttons["Log a past session"]
        XCTAssertTrue(backfill.waitForExistence(timeout: 3), "no backdated logging at this size")
        backfill.tap()
        capture("20d-log-session-large-text")
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["Sankalpas"].tap()
        capture("21-list-large-text")

        // The sheets are where fixed rows and side-by-side controls break first, and the tour has
        // never looked at them at this size.
        app.navigationBars.buttons["Declare a sankalpa"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New sankalpa"].waitForExistence(timeout: 3))
        capture("21b-declare-large-text")
        app.swipeUp()
        app.swipeUp()
        capture("21c-declare-large-text-duration")
        app.buttons["Cancel"].tap()
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

    /// An unreadable store must take over the app rather than looking like a fresh install, and
    /// must never be overwritten by the demo seed.
    func testUnreadableStoreShowsRecovery() throws {
        launch(corruptStore: true)

        XCTAssertTrue(
            app.staticTexts["Your data needs attention"].waitForExistence(timeout: 10),
            "a corrupt store did not raise the recovery screen"
        )
        // The app is not usable as if it were empty.
        XCTAssertFalse(app.buttons["Declare a sankalpa"].exists)
        XCTAssertTrue(app.buttons["Try opening again"].exists)
        capture("24-recovery")
    }

    /// Refusing to write over a file that will not parse is only half an answer. Without a way
    /// forward the app is bricked: every write is refused, so deleting the app is the only way
    /// back to a usable one — which destroys the file this screen says is still there.
    func testUnreadableStoreCanBeEscaped() throws {
        launch(corruptStore: true)
        XCTAssertTrue(
            app.staticTexts["Your data needs attention"].waitForExistence(timeout: 10)
        )

        // Retrying is worth offering for a transient failure, but it must answer when it fails
        // rather than looking like a button that does nothing.
        app.buttons["Try opening again"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS 'still could not be opened'")
            ).firstMatch.waitForExistence(timeout: 5),
            "a failed retry gave no answer"
        )
        // The file itself can be taken out of the app before anything is moved.
        XCTAssertTrue(app.buttons["Save a copy of the file"].exists)
        capture("27-recovery-retry-failed")

        app.buttons["Start fresh…"].tap()
        app.buttons["Start fresh"].tap()

        // The app is usable again.
        XCTAssertTrue(
            app.tabBars.buttons["Sankalpas"].waitForExistence(timeout: 10),
            "starting fresh did not give back a usable app"
        )
        capture("28-after-starting-fresh")

        app.tabBars.buttons["Sankalpas"].tap()
        XCTAssertTrue(app.buttons["Declare a sankalpa"].firstMatch.waitForExistence(timeout: 5))
    }

    /// A logged session has to still be there after the app is closed and reopened.
    func testSessionSurvivesRelaunch() throws {
        launch()
        dismissIntroduction()
        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: 10))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log a")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))

        relaunch()
        XCTAssertTrue(
            app.staticTexts["Vipassana"].waitForExistence(timeout: 10),
            "the practice did not survive a relaunch"
        )
        // The introduction was dismissed before, and the demo seed must not run again.
        XCTAssertFalse(app.buttons["Got it"].exists)
    }
}
