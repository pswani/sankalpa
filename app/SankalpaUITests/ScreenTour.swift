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
        XCTAssertTrue(vipassana.waitForExistence(timeout: UITestCase.timeout), "Today board did not render")
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
        XCTAssertTrue(finished.waitForExistence(timeout: UITestCase.timeout), "no finished sankalpa to open")
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
        XCTAssertTrue(paused.waitForExistence(timeout: UITestCase.timeout))
        paused.tap()
        capture("14-detail-paused")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let notStarted = app.staticTexts["Morning walk"]
        XCTAssertTrue(notStarted.waitForExistence(timeout: UITestCase.timeout))
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
        XCTAssertTrue(paused.waitForExistence(timeout: UITestCase.timeout))
        paused.tap()
        XCTAssertTrue(
            backfill.waitForExistence(timeout: UITestCase.timeout),
            "a paused sankalpa offered no way to record a forgotten session"
        )
        backfill.tap()
        capture("25-backfill-from-paused")
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Finished"].firstMatch.tap()
        let finished = app.staticTexts["Dream journaling"]
        XCTAssertTrue(finished.waitForExistence(timeout: UITestCase.timeout))
        finished.tap()
        XCTAssertTrue(
            backfill.waitForExistence(timeout: UITestCase.timeout),
            "a completed sankalpa offered no way to record a forgotten session"
        )
        capture("26-backfill-from-finished")
    }

    /// Dark Mode, where a hard-coded light colour would show up immediately.
    func testDarkMode() throws {
        launch(dark: true)
        dismissIntroduction()
        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: UITestCase.timeout))
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
        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: UITestCase.timeout))
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
        XCTAssertTrue(backfill.waitForExistence(timeout: UITestCase.timeout), "no backdated logging at this size")
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

    /// A service that has never answered must take over the app rather than looking like a
    /// first run with nothing declared — which would invite declaring into a service that cannot
    /// store it.
    func testUnreachableServiceShowsRecovery() throws {
        launch(unreachableService: true)

        XCTAssertTrue(
            app.staticTexts["Your practice is out of reach"].waitForExistence(timeout: 20),
            "an unreachable service did not raise the recovery screen"
        )
        // The app is not usable as if the practice were simply empty.
        XCTAssertFalse(app.buttons["Declare a sankalpa"].exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
        capture("24-recovery")
    }

    /// Retrying is worth offering, because the service being briefly away is the common case. But
    /// a retry that changes nothing has to answer, or it reads as a broken button — and the answer
    /// has to name the address, which is the one thing that lets someone check it themselves.
    func testFailedRetryOnUnreachableServiceAnswers() throws {
        launch(unreachableService: true)
        XCTAssertTrue(
            app.staticTexts["Your practice is out of reach"].waitForExistence(timeout: 20)
        )

        app.buttons["Try again"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS 'still could not be reached'")
            ).firstMatch.waitForExistence(timeout: 20),
            "a failed retry gave no answer"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", UITestCase.unreachableServiceDisplayText)
            ).firstMatch.exists,
            "the recovery screen did not say where it was looking"
        )
        capture("27-recovery-retry-failed")
    }

    /// A logged session has to still be there after the app is closed and reopened.
    func testSessionSurvivesRelaunch() throws {
        launch()
        dismissIntroduction()
        XCTAssertTrue(app.staticTexts["Vipassana"].waitForExistence(timeout: UITestCase.timeout))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log a")).firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Session logged"].waitForExistence(timeout: UITestCase.timeout),
            "the session was not accepted"
        )

        relaunch()
        XCTAssertTrue(
            app.staticTexts["Vipassana"].waitForExistence(timeout: UITestCase.timeout),
            "the practice did not survive a relaunch"
        )
        // The introduction was dismissed before, so a relaunch is a second run, not a first one.
        XCTAssertFalse(app.buttons["Got it"].exists)
    }

    // MARK: - Away from the service

    /// The practice has to still be there when the Mac is not. This is the difference between an
    /// app that is useless away from home and one that is not, and it is the whole of requirement
    /// 2 as far as the screens are concerned.
    func testPracticeIsStillReadableWhenTheServiceIsAway() throws {
        launch()
        dismissIntroduction()
        expect(app.staticTexts["Vipassana"], "the practice did not load while online")

        relaunchOffline()

        // Not the recovery screen: there is a copy on the phone, so it gets shown.
        expect(
            app.staticTexts["Vipassana"],
            "the phone's copy was not shown when the service was out of reach"
        )
        XCTAssertFalse(
            app.staticTexts["Your practice is out of reach"].exists,
            "a cached practice still raised the recovery screen"
        )
        // And it says so, rather than passing the copy off as current.
        expect(
            text(containing: "Showing this phone's copy"),
            "nothing said the practice might be behind"
        )
        capture("40-offline-cached-practice")
    }

    /// Logging is the one thing that must work away from the service, so the tap has to be offered
    /// and has to move the period — otherwise the user has no way to record a session they did.
    func testASessionCanBeLoggedWhileTheServiceIsAway() throws {
        launch()
        dismissIntroduction()
        expect(app.staticTexts["Vipassana"], "the practice did not load while online")

        relaunchOffline()
        expect(app.staticTexts["Gym"], "the phone's copy was not shown")

        let logButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Log a")
        ).firstMatch
        tap(logButton, "there was no way to log a session while the service was away")

        expect(
            text(containing: "waiting to be sent"),
            "a session logged offline was not reported as waiting"
        )
        capture("41-offline-session-waiting")
    }

    /// Where the service is has to be askable: on a real phone `localhost` is the phone, so
    /// without this screen the app can never find the Mac at all.
    func testTheServiceComputerCanBeChanged() throws {
        launch()
        dismissIntroduction()
        openTab("Sankalpas")

        // The row carries the computer's name as well as the label, so it is matched on shape —
        // the same way the "All N sessions" button is.
        let serviceRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Sankalpa service")
        ).firstMatch
        tap(serviceRow, "the list offered no way to see where the service is")
        expect(app.navigationBars["Sankalpa service"], "the service settings did not open")
        // It shows where it is looking, which is the thing a person needs in order to correct it.
        expect(text(containing: "localhost"), "the settings did not say which computer is in use")
        capture("42-service-settings")

        app.buttons["Cancel"].tap()
    }
}
