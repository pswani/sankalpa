import SwiftUI
import SankalpaCore
import SankalpaStorage

@main struct PracticeApp: App {
    @State private var model: PracticeModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        var url = FileStore.defaultURL()
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let name = env["PRACTICE_TEST_STORE"] {
            url = url.deletingLastPathComponent().appendingPathComponent("test-\(URL(fileURLWithPath: name).lastPathComponent).json")
            if ProcessInfo.processInfo.arguments.contains("-reset-test-store") { try? FileManager.default.removeItem(at: url) }
            if ProcessInfo.processInfo.arguments.contains("-corrupt-test-store") {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("unreadable test fixture".utf8).write(to: url, options: .atomic)
            }
        }
        #endif
        let store = FileStore(fileURL: url)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo"), store.all().isEmpty, store.loadError == nil {
            DemoData.populate(store)
        }
        #endif
        _model = State(initialValue: PracticeModel(store: store))
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).tint(Ink.accent)
                .preferredColorScheme(forcedScheme)
                .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        if AppTime.day(from: Date()) != model.today { model.refresh() }
                    }
                }
        }
    }
    private var forcedScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-dark") { return .dark }
        #endif
        return nil
    }
}
#if DEBUG
private enum DemoData {
    static func populate(_ store: FileStore) {
        let now = SystemClock().now(), today = SystemClock().today()
        let examples: [(String, ActionType, PeriodUnit, Int, LifecycleState)] = [
            ("Morning stillness", .meditation, .day, 2, .inProgress),
            ("Move with intention", .physicalActivity, .week, 4, .inProgress),
            ("A quieter breath", .pranayama, .day, 1, .paused),
            ("Evening reflection", .observance, .day, 1, .completedSuccessfully),
            ("Start small", .physicalActivity, .day, 1, .notStarted),
            ("An earlier chapter", .observance, .day, 1, .stopped),
            ("A future intention", .meditation, .week, 2, .notStarted)
        ]
        do {
            for (index, example) in examples.enumerated() {
                let (title, action, unit, times, state) = example
                let start = index == 4 ? today : today.addingDays(index == 6 ? 3 : (index == 5 ? -180 : -21))
                let beginning = CalendarMoment.startOfDay(start)
                var item = try Sankalpa.declare(Declaration(title: title, description: index == 0 ? "A moment to settle, listen, and begin again." : "Make space for what matters, one session at a time.", actionType: action, startDate: start, periodUnit: unit, timesPerPeriod: times, periodCount: unit == .day ? 180 : nil), now: min(beginning, now))
                if state != .notStarted { try item.begin(BeginTiming(now: beginning)) }
                var sessions: [Session] = []
                if state != .notStarted {
                    let endOffset = index == 5 ? 10 : 20
                    for offset in 0..<endOffset where offset % 4 != 2 {
                        let time = CalendarMoment(day: start.addingDays(offset), hour: 7)
                        sessions.append(try item.logSession(occurredAt: time, now: now))
                    }
                    if state == .paused { try item.pause(now: .startOfDay(today.addingDays(-1))) }
                    if state == .completedSuccessfully { try item.complete(.successfully, now: .startOfDay(today)) }
                    if state == .stopped { try item.stop(now: .startOfDay(start.addingDays(11))) }
                }
                try store.save(item)
                for session in sessions { try store.save(session) }
            }
        } catch { assertionFailure("Invalid review fixtures: \(error)") }
    }
}
#endif
