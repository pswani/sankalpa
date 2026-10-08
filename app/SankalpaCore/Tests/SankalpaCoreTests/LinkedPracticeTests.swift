import Foundation
import Testing
@testable import SankalpaCore

@Suite("Linked commitments")
struct LinkedPracticeTests {
    func root() throws -> Sankalpa {
        var root = try Sankalpa.declare(Declaration(title: "Sit", actionType: .meditation,
                startDate: day(2026, 7, 1), periodUnit: .day, timesPerPeriod: 1, periodCount: 40), now: moment(2026, 7, 1, 6))
        try root.begin(.init(now: moment(2026, 7, 1, 6)))
        return root
    }
    @Test("Extension preserves the source and copies provenance while later timelines diverge")
    func independentVows() throws {
        var source = try root()
        let before = source
        var child = try source.extended(totalPeriodCount: 90, now: moment(2026, 7, 30, 12))
        #expect(source == before)
        #expect(source.endDate == day(2026, 8, 9))
        #expect(child.endDate == day(2026, 9, 28))
        #expect(child.seriesId == source.id && child.extensionOf == source.id)
        #expect(child.lifecycle == source.lifecycle)
        try source.complete(.successfully, now: moment(2026, 8, 10, 12))
        try child.pause(now: moment(2026, 8, 11, 12))
        let grandchild = try child.extended(totalPeriodCount: 180, now: moment(2026, 8, 12, 12))
        #expect(grandchild.seriesId == source.id && grandchild.extensionOf == child.id)
        #expect(grandchild.state == .paused)
        #expect(grandchild.lifecycle.transitions.first?.originSankalpaId == source.id)
        #expect(grandchild.lifecycle.transitions.last?.originSankalpaId == child.id)
        try PracticeValidation.validate([source, child, grandchild], sessions: [])
    }
    @Test("One fact contributes to eligible peers only and unrelated matching vows stay separate")
    func performedTimeEligibility() throws {
        let source = try root()
        var child = try source.extended(totalPeriodCount: 90, now: moment(2026, 7, 30, 12))
        try child.pause(now: moment(2026, 7, 31, 8))
        let fact = try source.logSession(occurredAt: moment(2026, 7, 31, 9), now: moment(2026, 7, 31, 10))
        let unrelated = try root()
        #expect(SessionContributions.contributors(fact, members: [source, child, unrelated]).map(\.id) == [source.id])
        #expect(throws: SessionNotLoggable.self) { try child.logSession(occurredAt: fact.occurredAt, now: fact.loggedAt) }
    }
    @Test("Old starts can be extended and inherited pauses are retained")
    func oldStart() throws {
        var source = try Sankalpa.declare(Declaration(title: "Observe", actionType: .observance,
                startDate: day(2024, 2, 29), periodUnit: .year, timesPerPeriod: 1, periodCount: 1), now: moment(2024, 2, 29, 6))
        try source.begin(.init(now: moment(2024, 2, 29, 6)))
        let child = try source.extended(totalPeriodCount: 3, now: moment(2026, 10, 7, 12))
        #expect(child.startDate == source.startDate && child.endDate == day(2027, 2, 27))
        #expect(throws: DeclarationError.self) {
            try Sankalpa.declare(Declaration(title: "New", actionType: .observance, startDate: source.startDate,
                   periodUnit: .year, timesPerPeriod: 1), now: moment(2026, 10, 7, 12))
        }
    }
    @Test("Invalid extension durations, source states and historical end dates are rejected")
    func restrictions() throws {
        var source = try root()
        for count in [0, 39, 40, 3651] {
            #expect(throws: (any Error).self) { try source.extended(totalPeriodCount: count, now: moment(2026, 7, 30, 12)) }
        }
        #expect(throws: ExtensionError.endsInPast) { try source.extended(totalPeriodCount: 41, now: moment(2026, 8, 20, 12)) }
        let todayEnd = try source.extended(totalPeriodCount: 41, now: moment(2026, 8, 10, 12))
        #expect(todayEnd.endDate == day(2026, 8, 10))
        try source.stop(now: moment(2026, 7, 31, 12))
        #expect(throws: ExtensionError.sourceNotExtendable) { try source.extended(totalPeriodCount: 90, now: moment(2026, 8, 1, 12)) }
    }
    @Test("Two successful vows retain two wins and historical contributions after completion")
    func twoWins() throws {
        var source = try root()
        var child = try source.extended(totalPeriodCount: 90, now: moment(2026, 7, 30, 12))
        let fact = try child.logSession(occurredAt: moment(2026, 7, 31, 9), now: moment(2026, 7, 31, 10))
        try source.complete(.successfully, now: moment(2026, 8, 10, 12))
        #expect(child.state == .inProgress)
        try child.complete(.successfully, now: moment(2026, 9, 29, 12))
        let members = [source, child]
        #expect(members.filter { $0.state == .completedSuccessfully }.count == 2)
        #expect(SessionContributions.contributors(fact, members: members).count == 2)
        try PracticeValidation.validate(members, sessions: [fact])
        try PracticeValidation.validate(members, sessions: [])
        #expect(members.allSatisfy { $0.state == .completedSuccessfully })
    }

}
