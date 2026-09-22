import XCTest

/// What every UI test needs to drive this app, in one place.
///
/// The two things that matter here are isolation and honesty. Each test gets its own store file
/// and wipes it first, so no test can read, write or depend on another's data — or on a real
/// practice history that happens to be on the simulator. And every helper that cannot do what it
/// was asked fails the test rather than carrying on: a tap that silently misses is the one thing
/// that turns a UI suite into decoration.
class UITestCase: XCTestCase {

    var app: XCUIApplication!

    /// Long enough for a cold launch on a busy machine, short enough that a hang is still
    /// reported as a failure rather than as a timed-out run.
    static let timeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Launching

    /// Launches with optional overrides. Appearance and text size are set before launch so the
    /// first frame is already in the right mode.
    ///
    /// - Parameter demo: seed the five example sankalpas. Tests that build their own fixture
    ///   through the UI pass `false`, which is also the state a real first run is in.
    func launch(
        demo: Bool = true,
        dark: Bool = false,
        corruptStore: Bool = false,
        contentSize: String? = nil
    ) {
        XCUIDevice.shared.orientation = .portrait
        app.launchEnvironment["SANKALPA_TEST_STORE"] = UUID().uuidString
        app.launchArguments = ["-resetStore", "-resetIntroduction"]
        if demo { app.launchArguments.append("-demo") }
        if dark { app.launchArguments.append("-forceDarkMode") }
        if corruptStore { app.launchArguments.append("-corruptStore") }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
    }

    /// Relaunches against the same store without wiping it, to prove data survived.
    ///
    /// The seed and reset arguments are dropped, which is the point: if `-demo` ran again the
    /// relaunch would prove nothing, and a store that was deliberately cleared has to stay clear.
    func relaunch() {
        app.terminate()
        app.launchArguments.removeAll {
            $0 == "-resetStore" || $0 == "-demo" || $0 == "-resetIntroduction"
        }
        app.launch()
    }

    // MARK: - Finding things

    /// Scrolls until the element is actually on screen.
    ///
    /// An element that merely `exists` can still be off screen, and tapping it then silently
    /// misses — the test goes green having done nothing.
    @discardableResult
    func reveal(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
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
    /// store there is nothing to dismiss, and a journey that declares its own fixture should call
    /// this after the first declare rather than at launch.
    func dismissIntroduction(capturingAs name: String? = nil, timeout: TimeInterval = 5) {
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
