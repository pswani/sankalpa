import XCTest

/// What every UI test needs to drive this app, in one place.
///
/// The two things that matter here are isolation and honesty. The practice now lives in the
/// service, so isolation comes from pointing the app at a throwaway one — `scripts/uitest.sh`
/// starts a fresh backend per test class and passes its address in, which is what keeps a run from
/// inheriting the last one's sankalpas or touching a real practice. And every helper that cannot
/// do what it was asked fails the test rather than carrying on: a tap that silently misses is the
/// one thing that turns a UI suite into decoration.
class UITestCase: XCTestCase {

    var app: XCUIApplication!

    /// Long enough for a cold launch on a busy machine, short enough that a hang is still
    /// reported as a failure rather than as a timed-out run.
    ///
    /// It went up when the practice moved into the service. First paint is no longer a file read:
    /// it is a list request plus a lifecycle and a session read per sankalpa, against a JVM that
    /// may still be warming up on the first test of a run. The old three- and five-second content
    /// waits were measuring the network, not the app.
    static let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Launching

    /// Where the service for this run lives, passed in by `scripts/uitest.sh`.
    ///
    /// There is deliberately no default. Falling back to the app's own address would point the
    /// suite at whatever is running on this Mac — quite possibly a real practice. Worse, the run would
    /// report ordinary test failures rather than saying it was misconfigured, which is exactly how
    /// a whole run gets spent chasing the wrong thing.
    static func serviceURL(file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let url = ProcessInfo.processInfo.environment["SANKALPA_API_BASE_URL"] else {
            XCTFail(
                """
                SANKALPA_API_BASE_URL was not set, so there is no service to test against. \
                Run the UI suites with scripts/uitest.sh (or scripts/test.sh), which starts a \
                throwaway service per test class and passes its address in.
                """,
                file: file, line: line
            )
            return ""
        }
        return url
    }

    /// A port nothing is listening on, for driving the app's behaviour when the service is out of
    /// reach. This replaces the old corrupt-store argument: there is no local file to damage any
    /// more, and an unreachable service is the failure that actually happens now.
    static let unreachableServiceURL = "http://localhost:9"
    /// How the app names that computer back to the user. The screens show where to look, not a
    /// URL, so this is what a test should expect to read.
    static let unreachableServiceDisplayText = "localhost:9"

    /// Launches with optional overrides. Appearance and text size are set before launch so the
    /// first frame is already in the right mode.
    ///
    /// - Parameters:
    ///   - unreachableService: point the app at a service that will not answer.
    ///   - offline: keep the service address but behave as though it cannot be reached, which is
    ///     the only way to drive the offline screens from inside the simulator.
    ///   - keepCache: leave the phone's copy of the practice in place. Every launch starts from
    ///     nothing by default — the cache is built to survive, so a test that did not ask would
    ///     otherwise inherit the last run's practice.
    func launch(
        dark: Bool = false,
        unreachableService: Bool = false,
        offline: Bool = false,
        keepCache: Bool = false,
        contentSize: String? = nil
    ) {
        XCUIDevice.shared.orientation = .portrait
        app.launchEnvironment["SANKALPA_API_BASE_URL"] = unreachableService
            ? UITestCase.unreachableServiceURL
            : UITestCase.serviceURL()
        app.launchArguments = ["-resetIntroduction"]
        if !keepCache { app.launchArguments.append("-resetCache") }
        if offline { app.launchArguments.append("-offline") }
        if dark { app.launchArguments.append("-forceDarkMode") }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
    }

    /// Relaunches with the phone's copy intact but the service out of reach, which is what a
    /// second launch away from the Mac actually looks like.
    func relaunchOffline() {
        app.terminate()
        app.launchArguments.removeAll { $0 == "-resetIntroduction" || $0 == "-resetCache" }
        app.launchArguments.append("-offline")
        app.launch()
    }

    /// Relaunches against the same service, to prove what was recorded is still there.
    ///
    /// The introduction reset is dropped so the relaunch is a genuine second run rather than a
    /// first one repeated.
    func relaunch() {
        app.terminate()
        app.launchArguments.removeAll { $0 == "-resetIntroduction" || $0 == "-resetCache" }
        app.launch()
    }

    // MARK: - Finding things

    /// Scrolls until the element is actually on screen.
    ///
    /// An element that merely `exists` can still be off screen, and tapping it then silently
    /// misses — the test goes green having done nothing.
    ///
    /// Waiting and scrolling are interleaved, because there are two reasons an element is not
    /// there yet and they need opposite things. Content still arriving from the service needs a
    /// moment of patience — without it a screen is swiped straight past before it has filled in,
    /// and the failure reads as "the button is missing" rather than "the practice had not arrived
    /// yet". A row in a lazily rendered list is the other way round: it does not exist *until*
    /// something scrolls near it, so waiting alone would never find it.
    @discardableResult
    func reveal(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Reveals the element and taps it, failing with the given reason if it never appears.
    func tap(
        _ element: XCUIElement,
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(reveal(element), reason, file: file, line: line)
        element.tap()
    }

    /// Asserts an element turns up, with a sentence saying what its absence would mean.
    func expect(
        _ element: XCUIElement,
        _ reason: String,
        timeout: TimeInterval = UITestCase.timeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), reason, file: file, line: line)
    }

    /// The first static text containing `fragment` — for the phrases the app derives rather than
    /// spells out, like "1 of 2 sessions".
    func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }

    /// Goes back one level in the current navigation stack.
    func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Dismisses the one-time introduction if it is showing.
    ///
    /// It lives on the board, which only exists once there is a sankalpa on it — so on an empty
    /// practice there is nothing to dismiss, and a journey that declares its own fixture should
    /// call this after the first declare rather than at launch. Waiting the full timeout is what
    /// makes it double as "wait until the first refresh has landed".
    func dismissIntroduction(
        capturingAs name: String? = nil,
        timeout: TimeInterval = UITestCase.timeout
    ) {
        let gotIt = app.buttons["Got it"]
        guard gotIt.waitForExistence(timeout: timeout) else { return }
        if let name { capture(name) }
        gotIt.tap()
    }

    /// Opens a tab by its label, which is the one selector that works the same on every device.
    func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name].exists
            ? app.tabBars.buttons[name]
            : app.buttons[name]
        tap(tab, "the \(name) tab could not be reached")
    }

    // MARK: - Evidence

    /// Attaches a screenshot under a stable name, so the report can point at it.
    func capture(_ name: String) {
        // Let presentation and push animations finish, so screenshots are not caught mid-blur.
        Thread.sleep(forTimeInterval: 0.9)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
