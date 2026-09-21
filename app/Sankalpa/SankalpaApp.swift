import SwiftUI
import SankalpaCore

@main
struct SankalpaApp: App {
    @State private var model = AppModel()
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
        }
    }
}
