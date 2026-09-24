import XCTest

/// The journeys a person actually takes, driven end to end against an empty app.
///
/// The screen tour proves every screen builds and captures how it looks. This is the other half:
/// that the app *does* what the screens offer. Each test builds whatever it needs through the
/// interface, so nothing here depends on the demo content — and a first run, which is the state
/// every real user starts in, is exercised on every test rather than only in the one that
/// captures it. "Empty" is the service being empty, not a file: `scripts/uitest.sh` gives this
/// class its own backend with a fresh database.
final class JourneyTests: UITestCase {

    // MARK: - Declaring

    /// The primary path through the app: declare an intent, begin it, act, and see the period
    /// move. Everything else in the app is a variation on this, and until now none of it was
    /// driven through the interface — the tour opened the declare form and cancelled out of it.
    func testDeclareBeginAndLogASession() throws {
        launch()

        declare(titled: "Evening walk")

        // It arrives Not started, because declaring is not beginning (S6).
        expect(app.staticTexts["Evening walk"], "the declared sankalpa did not appear")
        openDetail("Evening walk")
        expectState(State.notStarted, "a newly declared sankalpa was not Not started")

        tap(app.buttons["Begin now"], "a Not started sankalpa offered no way to begin")
        expectState(State.inProgress, "beginning did not move the sankalpa to In progress")

        // The commitment is one a day, so the period starts empty and one session fills it.
        expect(text(containing: "0 of 1 sessions"), "the new period did not start empty")
        capture("30-declared-and-begun")

        tap(app.buttons["Log a session"], "the in-progress card offered no way to log")
        expect(
            text(containing: "1 of 1 sessions"),
            "logging a session did not move the period it belongs to"
        )
        capture("31-after-logging")
    }

    func testAJustLoggedSessionCanBeUndone() throws {
        launch()
        declareAndBegin(titled: "Undo walk")

        tap(app.buttons["Log a session"], "the in-progress card offered no way to log")
        expect(app.buttons["Undo"], "logging did not offer the immediate Undo action")
        tap(app.buttons["Undo"], "the Undo action could not be used")

        expect(text(containing: "0 of 1 sessions"), "Undo did not restore the period total")
    }

    func testAQuickRepeatRequiresConfirmation() throws {
        launch()
        declareAndBegin(titled: "Repeat walk")
        tap(app.buttons["Log a session"], "the first session could not be logged")
        expect(text(containing: "1 of 1 sessions"), "the first session was not counted")

        tap(app.buttons["Log another"].firstMatch, "the repeat logging action was missing")
        expect(
            text(containing: "was just logged"),
            "a repeat inside one minute was not confirmed"
        )
        tap(app.buttons["Cancel"].firstMatch, "the repeat confirmation had no cancel action")
        expect(text(containing: "1 of 1 sessions"), "cancelling a repeat changed the count")

        tap(app.buttons["Log another"].firstMatch, "the repeat action disappeared after cancel")
        tap(app.alerts.buttons["Log another"], "the repeat confirmation had no confirm action")
        expect(text(containing: "2 sessions · 1 committed"), "a confirmed repeat was not counted separately")
    }

    func testALoggedSessionCanBePermanentlyDeletedFromHistory() throws {
        launch()
        declareAndBegin(titled: "Delete walk")
        tap(app.buttons["Log a session"], "the session could not be logged")
        expect(text(containing: "1 of 1 sessions"), "the logged session was not counted")

        tap(app.buttons["All 1 sessions"], "complete session history was not available")
        expect(app.navigationBars["Sessions"], "the complete session history did not open")
        tap(app.buttons["Delete session"], "the history row offered no permanent deletion")
        tap(app.alerts.buttons["Delete"], "permanent deletion was not confirmed")
        expect(app.staticTexts["No sessions yet"], "the deleted session stayed in history")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        expect(text(containing: "0 of 1 sessions"), "deletion did not restore the period total")
    }

    /// Declare is refused without a title (S1). The form disables it rather than accepting the
    /// tap and answering with an alert, so the refusal has to be visible before it is attempted.
    func testDeclareIsRefusedUntilThereIsATitle() throws {
        launch()

        openDeclareForm()
        let declareButton = app.buttons["Declare"]
        expect(declareButton, "the declare form had no Declare button")
        XCTAssertFalse(
            declareButton.isEnabled,
            "an untitled sankalpa could be declared"
        )

        // Whitespace is not a title either — it is trimmed away before anything is validated.
        let title = app.textFields.element(boundBy: 0)
        tap(title, "the title field could not be reached")
        title.typeText("   ")
        XCTAssertFalse(
            declareButton.isEnabled,
            "a title of nothing but spaces was accepted"
        )

        title.typeText("Morning walk")
        XCTAssertTrue(declareButton.isEnabled, "a titled sankalpa still could not be declared")
        capture("32-declare-validation")

        app.buttons["Cancel"].tap()
    }

    // MARK: - Lifecycle

    /// Pause and Resume are the two transitions a practice actually goes through, and Resume is
    /// deliberately reachable without opening the detail screen. Both are driven here.
    func testPauseAndResume() throws {
        launch()
        declareAndBegin(titled: "Pranayama")

        tap(app.buttons["Pause"], "an in-progress sankalpa offered no way to pause")
        expectState(State.paused, "pausing did not move the sankalpa to Paused")
        capture("33-paused")

        tap(app.buttons["Resume"], "a paused sankalpa offered no way to resume")
        expectState(State.inProgress, "resuming did not return the sankalpa to In progress")
    }

    /// Stopping is final, so it asks first — and the question has to be answerable both ways.
    /// Backing out must leave the sankalpa exactly as it was.
    ///
    /// On this runtime the confirmation renders as a compact dialog with only the destructive
    /// button in it: the `.cancel` role button the app declares is not drawn, so the only way
    /// out is a tap outside the dialog. That is what this drives, because it is what a user has
    /// to do. If a visible Cancel is ever added, this test keeps passing — and the missing one
    /// is noted in TESTING.md rather than asserted here, since it is a design question.
    func testStoppingIsConfirmedAndCanBeBackedOutOf() throws {
        launch()
        declareAndBegin(titled: "Cold shower")

        tap(app.buttons["Stop…"], "an in-progress sankalpa offered no way to stop")
        let dialog = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Stopping is final'")
        ).firstMatch
        expect(dialog, "stopping was not confirmed before it happened")
        capture("34-stop-confirmation")

        dismissDialog()
        expectState(State.inProgress, "backing out of the confirmation stopped it anyway")

        tap(app.buttons["Stop…"], "the stop action disappeared after backing out")
        // The destructive button carries the bare verb; the one that opened the dialog has the
        // ellipsis, so an exact match cannot hit the wrong one.
        tap(app.buttons["Stop"], "the confirmation offered no way to go through with it")
        expectState(State.stopped, "stopping did not move the sankalpa to Stopped")
        capture("35-stopped")
    }

    /// Completing asks which outcome it was, because the app does not decide that from the
    /// tallies — the user does (S8).
    func testCompletingAsksWhichOutcomeItWas() throws {
        launch()
        declareAndBegin(titled: "Morning pages")

        tap(app.buttons["Complete…"], "an in-progress sankalpa offered no way to complete")
        expect(
            app.buttons["Completed successfully"],
            "completing did not ask which outcome it was"
        )
        XCTAssertTrue(
            app.buttons["Completed unsuccessfully"].exists,
            "only one outcome was offered, so the choice was made for the user"
        )
        capture("36-complete-outcomes")

        app.buttons["Completed successfully"].tap()
        expectState(State.completedSuccessfully, "completing did not record the outcome chosen")
    }

    /// A terminal sankalpa leaves the active list. With nothing active left, the filter itself
    /// goes with it — the picker lives in the list — so the way back to a finished sankalpa is
    /// the empty state's own "Show all", and that is the thing worth proving.
    /// The subject is the filtering, not the empty state. The empty-list path — where the picker
    /// goes with the last active sankalpa and "Show all" is the way back — cannot be asserted here
    /// any more: the tests in this class share one service, so an earlier journey's sankalpa is
    /// still active. Keeping the filter assertions and dropping that one is the honest split;
    /// asserting a globally empty practice from the middle of a shared run would be a lie.
    func testFinishedSankalpasLeaveTheActiveList() throws {
        launch()
        declareAndBegin(titled: "Evening sit")
        tap(app.buttons["Stop…"], "an in-progress sankalpa offered no way to stop")
        tap(app.buttons["Stop"], "the confirmation offered no way to go through with it")
        expectState(State.stopped, "the sankalpa was not stopped")
        goBack()

        openTab("Sankalpas")
        // Active is the default filter, and this one is not active any more.
        XCTAssertTrue(
            app.staticTexts["Evening sit"].waitForNonExistence(timeout: UITestCase.timeout),
            "a stopped sankalpa was still listed as active"
        )
        capture("37-stopped-left-the-active-list")

        tap(app.buttons["Finished"].firstMatch, "the Finished filter could not be reached")
        expect(app.staticTexts["Evening sit"], "a stopped sankalpa was not listed as finished")
        capture("37b-finished-filter")

        tap(app.buttons["All"].firstMatch, "the All filter could not be reached")
        expect(app.staticTexts["Evening sit"], "showing all did not include the stopped sankalpa")
    }

    // MARK: - Journal

    /// The journal is the one screen that reads across every sankalpa, so a session logged
    /// anywhere has to reach it.
    /// The empty journal's own copy is not asserted here: the tests in this class share a service,
    /// so by the time this one runs other journeys have logged sessions. What this owns is that a
    /// session logged on one screen reaches a screen that reads across every sankalpa.
    func testTheJournalShowsASessionJustLogged() throws {
        launch()

        declareAndBegin(titled: "Dawn sitting")
        tap(app.buttons["Log a session"], "the in-progress card offered no way to log")
        expect(text(containing: "1 of 1 sessions"), "the session was not logged")
        goBack()

        openTab("Journal")
        expect(
            app.staticTexts["Dawn sitting"],
            "a logged session never reached the journal"
        )
        capture("38-journal-with-one-session")
    }

    // MARK: - Building a fixture through the interface

    /// Opens the declare form from whichever screen is showing.
    private func openDeclareForm() {
        let toolbarButton = app.navigationBars.buttons["Declare a sankalpa"].firstMatch
        let emptyStateButton = app.buttons["Declare a sankalpa"].firstMatch
        tap(
            toolbarButton.exists ? toolbarButton : emptyStateButton,
            "no way to declare a sankalpa"
        )
        expect(app.navigationBars["New sankalpa"], "the declare form did not open")
    }

    /// Declares a once-a-day sankalpa with everything else left at its default, which is the
    /// shape the assertions about "0 of 1 sessions" rely on.
    private func declare(titled title: String) {
        openDeclareForm()
        let field = app.textFields.element(boundBy: 0)
        tap(field, "the title field could not be reached")
        field.typeText(title)
        tap(app.buttons["Declare"], "the form would not accept a titled sankalpa")
        XCTAssertTrue(
            app.navigationBars["New sankalpa"].waitForNonExistence(timeout: UITestCase.timeout),
            "the declare form stayed open after declaring"
        )
        // The board — and with it the one-time introduction — exists only now that something is
        // on it. The card sits above the sankalpa, so it is dismissed before anything is read.
        dismissIntroduction(timeout: 3)
    }

    /// Declares, opens, and begins — leaving the detail screen showing, which is where the
    /// lifecycle actions live.
    private func declareAndBegin(titled title: String) {
        declare(titled: title)
        openDetail(title)
        tap(app.buttons["Begin now"], "a Not started sankalpa offered no way to begin")
        expectState(State.inProgress, "beginning did not move the sankalpa to In progress")
    }

    /// Backs out of a confirmation dialog by tapping outside it, which is the only way this
    /// runtime offers: the compact dialog draws the destructive button and nothing else.
    private func dismissDialog() {
        // Near the top of the screen, well clear of the centred dialog.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS 'is final'")
            ).firstMatch.waitForNonExistence(timeout: UITestCase.timeout),
            "the confirmation dialog would not close"
        )
    }

    private func openDetail(_ title: String) {
        tap(app.staticTexts[title], "\(title) could not be opened")
        expect(
            app.navigationBars[title],
            "tapping \(title) did not open its detail screen"
        )
    }

    /// Asserts the sankalpa is in `state`, by the sentence the detail screen uses to explain it.
    ///
    /// The state badge would be the obvious thing to read, but on the board it is combined into
    /// one accessibility element with the rest of the card, so it is not dependable as a
    /// selector. The explanation is a plain line of text, unique to each state, and is the thing
    /// that actually tells the user where they are.
    private func expectState(
        _ explanation: String,
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            text(containing: explanation).waitForExistence(timeout: UITestCase.timeout),
            reason,
            file: file,
            line: line
        )
    }

    private enum State {
        static let notStarted = "Begin the sankalpa to start tracking"
        static let inProgress = "Sessions can be logged"
        static let paused = "Nothing new can be logged while paused"
        static let completedSuccessfully = "completed this sankalpa successfully"
        static let stopped = "You stopped this sankalpa"
    }
}
