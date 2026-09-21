import SwiftUI
import SankalpaCore
import SankalpaStorage

@main
struct SankalpaApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // The screen tour needs the first-run card back on every launch. Clearing the stored value
        // rather than overriding it from the argument domain leaves "Got it" able to dismiss it,
        // which is the behaviour being reviewed.
        if ProcessInfo.processInfo.arguments.contains("-resetIntroduction") {
            UserDefaults.standard.removeObject(forKey: "hasSeenIntroduction")
        }
        #endif
        _model = State(initialValue: SankalpaApp.makeModel())
    }

    /// Builds the model, honouring the debug-only launch arguments the UI tour relies on.
    ///
    /// A UI test gets its own store file, so it is hermetic and can never touch a real practice
    /// history — and `-corruptStore` writes a deliberately broken file so the recovery screen is
    /// exercised for real rather than merely drawn.
    private static func makeModel() -> AppModel {
        var url = FileStore.defaultFileURL()
        var seedDemoData = false

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let name = ProcessInfo.processInfo.environment["SANKALPA_TEST_STORE"] {
            url = url.deletingLastPathComponent()
                .appendingPathComponent("test-\(name).json")
            if arguments.contains("-resetStore") {
                try? FileManager.default.removeItem(at: url)
            }
            if arguments.contains("-corruptStore") {
                try? Data("not a store".utf8).write(to: url, options: .atomic)
            }
        }
        seedDemoData = arguments.contains("-demo")
        #endif

        return AppModel(store: FileStore(fileURL: url), seedDemoData: seedDemoData)
    }

    /// Debug-only override used by the screen tour. The simulator's own appearance switch does not
    /// reliably repaint this runtime, and Dark Mode is worth verifying on every screen.
    private static var forcedColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-forceDarkMode") { return .dark }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Palette.accent)
                .preferredColorScheme(SankalpaApp.forcedColorScheme)
                .onChange(of: scenePhase) { _, phase in
                    // The day can roll over while the app is backgrounded, which changes which
                    // period is current.
                    if phase == .active { model.refresh() }
                }
                .task {
                    // An app left open across midnight would otherwise keep showing yesterday's
                    // period. The system tells us when the day changes; polling for it would be a
                    // timer running for the life of the app to catch one event.
                    let dayChanged = NotificationCenter.default.notifications(
                        named: .NSCalendarDayChanged
                    )
                    for await _ in dayChanged { model.refresh() }
                }
        }
    }
}
