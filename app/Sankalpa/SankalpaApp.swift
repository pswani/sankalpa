import SwiftUI
import SankalpaCore
import SankalpaStorage

@main
struct SankalpaApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // The UI suite needs the first-run card back on every launch. Clearing the stored value
        // rather than overriding it from the argument domain leaves "Got it" able to dismiss it,
        // which is the behaviour being reviewed.
        if ProcessInfo.processInfo.arguments.contains("-resetIntroduction") {
            UserDefaults.standard.removeObject(forKey: "hasSeenIntroduction")
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    /// Debug-only override used by the UI suite. The simulator's own appearance switch does not
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
                .task {
                    // Nothing is on screen until the service answers, so this is the first thing
                    // the app does.
                    await model.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back can mean the day rolled over, which changes which period is
                    // current, and that something else changed the practice while we were away.
                    if phase == .active {
                        Task { await model.refresh() }
                    }
                }
                .task {
                    // An app left open across midnight would otherwise keep showing yesterday's
                    // period. The system tells us when the day changes; polling for it would be a
                    // timer running for the life of the app to catch one event. Re-deriving is
                    // enough — the sessions have not changed, only which window is current.
                    let dayChanged = NotificationCenter.default.notifications(
                        named: .NSCalendarDayChanged
                    )
                    for await _ in dayChanged { model.rebuild() }
                }
        }
    }
}
