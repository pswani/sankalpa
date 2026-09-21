import Foundation
import SankalpaCore
import SankalpaStorage

/// Demo content for exploring the app, seeded only on an explicit `-demo` launch.
///
/// This is never part of a normal launch or a release build: a real practice history should not
/// have to be told apart from examples. Every sankalpa here is built through the real domain API —
/// declared, begun, logged — so the demo cannot contain a state the rules would not allow.
enum SampleData {

    static func seed(into store: FileStore, clock: SankalpaClock) {
        let now = clock.now()
        let today = now.day
        var sankalpas: [Sankalpa] = []
        var sessions: [Session] = []

        func add(_ built: (sankalpa: Sankalpa, sessions: [Session])) {
            sankalpas.append(built.sankalpa)
            sessions.append(contentsOf: built.sessions)
        }

        add(vipassana(today: today, now: now))
        add(gym(today: today, now: now))
        add(sudarshanKriya(today: today, now: now))
        add(dreamJournal(today: today, now: now))
        add(morningWalk(today: today, now: now))

        // Demo seeding is best-effort: if it cannot be written, the app simply starts empty rather
        // than failing to launch.
        try? store.replaceAll(sankalpas: sankalpas, sessions: sessions)
    }

    // MARK: - The requirement's first example

    /// "Do Vipassana twice everyday for 6 months" — started 40 days ago, kept well but not perfectly.
    private static func vipassana(
        today: CalendarDay, now: CalendarMoment
    ) -> (sankalpa: Sankalpa, sessions: [Session]) {
        let start = today.addingDays(-40)
        var sankalpa = declare(
            title: "Vipassana",
            description: "Two sittings a day, morning and evening, for six months.",
            actionType: .meditation,
            start: start,
            unit: .day,
            times: 2,
            count: 180,
            now: now
        )
        // Declared and begun effective the first day, but only recorded two days later — which is
        // the one backdated transition the rules allow, and what the audit trail shows.
        begin(
            &sankalpa,
            effectiveAt: CalendarMoment(day: start, hour: 6),
            recordedAt: CalendarMoment(day: start.addingDays(2), hour: 21, minute: 10)
        )

        var sessions: [Session] = []
        for offset in 0...40 {
            let dayOfPractice = start.addingDays(offset)
            guard dayOfPractice <= today else { break }
            // A convincing record: most days both sittings, some days only the morning one.
            let skipsEvening = offset % 7 == 3 || offset % 11 == 5
            let missesEntirely = offset % 13 == 6
            if missesEntirely { continue }
            record(&sankalpa, into: &sessions, day: dayOfPractice, hour: 6, minute: 15, now: now)
            if !skipsEvening {
                record(&sankalpa, into: &sessions, day: dayOfPractice, hour: 19, minute: 30, now: now)
            }
        }
        return (sankalpa, sessions)
    }

    // MARK: - The requirement's second example

    /// "Go to the gym for 4 times per week" — no duration, so it runs until it is stopped.
    private static func gym(
        today: CalendarDay, now: CalendarMoment
    ) -> (sankalpa: Sankalpa, sessions: [Session]) {
        let start = today.addingDays(-70)
        var sankalpa = declare(
            title: "Gym",
            description: "Strength work four times a week, no end date — until I stop.",
            actionType: .physicalActivity,
            start: start,
            unit: .week,
            times: 4,
            count: nil,
            now: now
        )
        begin(&sankalpa, at: CalendarMoment(day: start, hour: 7))

        var sessions: [Session] = []
        for week in 0..<11 {
            // Four most weeks, three in a couple of them, five in one good week.
            let visits: [Int]
            switch week {
            case 2, 6: visits = [0, 2, 4]
            case 4: visits = [0, 1, 3, 4, 5]
            default: visits = [0, 2, 4, 6]
            }
            for offsetInWeek in visits {
                let visitDay = start.addingDays(week * 7 + offsetInWeek)
                guard visitDay <= today else { continue }
                record(&sankalpa, into: &sessions, day: visitDay, hour: 18, minute: 0, now: now)
            }
        }
        return (sankalpa, sessions)
    }

    /// Paused a few days ago, so the Paused state and a fully paused period are both visible.
    private static func sudarshanKriya(
        today: CalendarDay, now: CalendarMoment
    ) -> (sankalpa: Sankalpa, sessions: [Session]) {
        let start = today.addingDays(-50)
        var sankalpa = declare(
            title: "Sudarshan Kriya",
            description: "Daily practice for 90 days.",
            actionType: .pranayama,
            start: start,
            unit: .day,
            times: 1,
            count: 90,
            now: now
        )
        begin(&sankalpa, at: CalendarMoment(day: start, hour: 6))

        var sessions: [Session] = []
        for offset in 0..<44 {
            let practiceDay = start.addingDays(offset)
            if offset % 9 == 4 { continue }
            record(&sankalpa, into: &sessions, day: practiceDay, hour: 6, minute: 30, now: now)
        }
        try? sankalpa.pause(now: CalendarMoment(day: today.addingDays(-6), hour: 21))
        return (sankalpa, sessions)
    }

    /// Finished and judged by the user as successful, which is the only way a sankalpa ever ends.
    private static func dreamJournal(
        today: CalendarDay, now: CalendarMoment
    ) -> (sankalpa: Sankalpa, sessions: [Session]) {
        let start = today.addingDays(-60)
        var sankalpa = declare(
            title: "Dream journaling",
            description: "Write down whatever I remember, every morning for 30 days.",
            actionType: .observance,
            start: start,
            unit: .day,
            times: 1,
            count: 30,
            now: now
        )
        begin(&sankalpa, at: CalendarMoment(day: start, hour: 7))

        var sessions: [Session] = []
        for offset in 0..<30 {
            if offset == 12 { continue }
            record(&sankalpa, into: &sessions, day: start.addingDays(offset), hour: 7, minute: 20, now: now)
        }
        try? sankalpa.complete(.successfully, now: CalendarMoment(day: today.addingDays(-29), hour: 9))
        return (sankalpa, sessions)
    }

    /// Declared with a start date still to come, so it waits in Not started.
    private static func morningWalk(
        today: CalendarDay, now: CalendarMoment
    ) -> (sankalpa: Sankalpa, sessions: [Session]) {
        let sankalpa = declare(
            title: "Morning walk",
            description: "Thirty minutes before breakfast, three times a week.",
            actionType: .physicalActivity,
            start: today.addingDays(3),
            unit: .week,
            times: 3,
            count: 12,
            now: now
        )
        return (sankalpa, [])
    }

    // MARK: - Helpers

    private static func declare(
        title: String,
        description: String,
        actionType: ActionType,
        start: CalendarDay,
        unit: PeriodUnit,
        times: Int,
        count: Int?,
        now: CalendarMoment
    ) -> Sankalpa {
        // Force-unwrapped deliberately: these literals are fixed, so a failure here is a programming
        // error in the sample data, not a runtime condition to handle.
        try! Sankalpa.declare(
            Declaration(
                title: title,
                description: description,
                actionType: actionType,
                startDate: start,
                periodUnit: unit,
                timesPerPeriod: times,
                periodCount: count
            ),
            now: now
        )
    }

    private static func begin(_ sankalpa: inout Sankalpa, at moment: CalendarMoment) {
        begin(&sankalpa, effectiveAt: moment, recordedAt: moment)
    }

    private static func begin(
        _ sankalpa: inout Sankalpa, effectiveAt: CalendarMoment, recordedAt: CalendarMoment
    ) {
        try! sankalpa.begin(BeginTiming(effectiveAt: effectiveAt, recordedAt: recordedAt))
    }

    /// Logs through the aggregate, so a sample session that the rules would refuse is simply
    /// never created.
    private static func record(
        _ sankalpa: inout Sankalpa,
        into sessions: inout [Session],
        day: CalendarDay,
        hour: Int,
        minute: Int,
        now: CalendarMoment
    ) {
        let occurredAt = CalendarMoment(day: day, hour: hour, minute: minute)
        guard occurredAt <= now, let session = try? sankalpa.logSession(occurredAt: occurredAt, now: now)
        else { return }

        // The aggregate stamps `loggedAt` with the clock, which would mark every sample session as
        // backdated. Restating it as a quarter of an hour after the session makes the sample read
        // like a history someone kept as they went, and leaves the Backdated badge meaning
        // something.
        sessions.append(
            Session.rehydrate(
                id: session.id,
                sankalpaId: session.sankalpaId,
                occurredAt: occurredAt,
                loggedAt: min(
                    now,
                    CalendarMoment(day: occurredAt.day, secondOfDay: occurredAt.secondOfDay + 900)
                )
            )
        )
    }
}
