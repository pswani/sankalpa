import Foundation
import Testing
@testable import SankalpaCore
@testable import SankalpaStorage

@Suite("API mapping")
struct APIMappingTests {

    private func decodeSankalpa(_ json: String) throws -> API.SankalpaResponse {
        try JSONDecoder().decode(API.SankalpaResponse.self, from: Data(json.utf8))
    }

    private func decodeTransitions(_ json: String) throws -> [API.LifecycleTransitionResponse] {
        try JSONDecoder().decode([API.LifecycleTransitionResponse].self, from: Data(json.utf8))
    }

    @Test("Builds a sankalpa from the service's own response")
    func mapsSankalpa() throws {
        let subject = try APIMapping.sankalpa(
            decodeSankalpa(Fixture.sankalpaJSON()),
            transitions: decodeTransitions(Fixture.transitionsJSON())
        )

        #expect(subject.title.value == "Vipassana")
        #expect(subject.actionType == .meditation)
        #expect(subject.commitment.startDate == day(2026, 9, 1))
        #expect(subject.commitment.periodUnit == .day)
        #expect(subject.commitment.timesPerPeriod.value == 2)
        #expect(subject.commitment.periodCount?.value == 30)
        #expect(subject.state == .inProgress)
        #expect(subject.lifecycle.transitions.count == 1)
    }

    /// The service sends `endDate`, but the app derives it from the commitment. The two must agree,
    /// or the detail screen and the service would be telling the user different things.
    @Test("The derived end date matches the one the service sends")
    func derivedEndDateAgreesWithTheService() throws {
        let response = try decodeSankalpa(Fixture.sankalpaJSON())
        let subject = try APIMapping.sankalpa(response, transitions: [])

        #expect(subject.commitment.endDate == WireFormat.day(from: response.endDate ?? ""))
    }

    @Test("An indefinite commitment has no duration and no end date")
    func mapsIndefiniteCommitment() throws {
        let subject = try APIMapping.sankalpa(
            decodeSankalpa(Fixture.sankalpaJSON(endDate: nil, periodCount: nil)),
            transitions: []
        )

        #expect(subject.commitment.periodCount == nil)
        #expect(subject.commitment.endDate == nil)
    }

    @Test(
        "Translates every enum the service spells in upper snake case",
        arguments: [
            ("MEDITATION", ActionType.meditation),
            ("PRANAYAMA", .pranayama),
            ("PHYSICAL_ACTIVITY", .physicalActivity),
            ("OBSERVANCE", .observance)
        ]
    )
    func translatesActionTypes(wire: String, expected: ActionType) {
        #expect(APIEnum.actionType(wire) == expected)
        #expect(APIEnum.wire(expected) == wire)
    }

    @Test(
        "Translates every lifecycle state",
        arguments: [
            ("NOT_STARTED", LifecycleState.notStarted),
            ("IN_PROGRESS", .inProgress),
            ("PAUSED", .paused),
            ("COMPLETED_SUCCESSFULLY", .completedSuccessfully),
            ("COMPLETED_UNSUCCESSFULLY", .completedUnsuccessfully),
            ("STOPPED", .stopped)
        ]
    )
    func translatesLifecycleStates(wire: String, expected: LifecycleState) {
        #expect(APIEnum.lifecycleState(wire) == expected)
    }

    /// The service names the outcomes `SUCCESSFUL`/`UNSUCCESSFUL` while the domain names them
    /// `successfully`/`unsuccessfully`. Sending the domain's spelling would be a 400.
    @Test("Sends the service's spelling of a completion outcome")
    func translatesCompletionOutcome() {
        #expect(APIEnum.wire(CompletionOutcome.successfully) == "SUCCESSFUL")
        #expect(APIEnum.wire(CompletionOutcome.unsuccessfully) == "UNSUCCESSFUL")
    }

    @Test("A value this version does not know about is reported, not guessed at")
    func refusesUnknownEnum() throws {
        let response = try decodeSankalpa(Fixture.sankalpaJSON(actionType: "BREATHWORK"))
        #expect(throws: WireDecodingError.self) {
            try APIMapping.sankalpa(response, transitions: [])
        }
    }

    /// The service allows a 200-character title; this app's own limit is 80. A stricter client is
    /// compatible with a laxer service, so a long title is shown shortened rather than hiding the
    /// sankalpa altogether.
    @Test("A title longer than this app allows is shortened, not rejected")
    func shortensAnOverLongTitle() throws {
        let long = String(repeating: "a", count: 200)
        let subject = try APIMapping.sankalpa(
            decodeSankalpa(Fixture.sankalpaJSON(title: long)), transitions: []
        )

        #expect(subject.title.value.count == Title.maxLength)
        #expect(subject.title.value.hasSuffix("…"))
    }

    @Test("Builds a session, keeping the moment it occurred apart from when it was logged")
    func mapsSession() throws {
        let json = """
        {"id":"\(Fixture.sessionId)","sankalpaId":"\(Fixture.sankalpaId)",
         "occurredAt":"2026-09-01T07:00:00","loggedAt":"2026-09-03T21:15:30.5"}
        """
        let subject = try APIMapping.session(
            JSONDecoder().decode(API.SessionResponse.self, from: Data(json.utf8))
        )

        #expect(subject.occurredAt == CalendarMoment(day: day(2026, 9, 1), hour: 7))
        #expect(subject.loggedAt == CalendarMoment(day: day(2026, 9, 3), hour: 21, minute: 15, second: 30))
        #expect(subject.wasBackdated)
    }

    @Test("A declaration goes out in the service's own shape")
    func buildsDeclareRequest() {
        let request = APIMapping.declareRequest(
            Declaration(
                title: "Gym",
                description: "Four times a week",
                actionType: .physicalActivity,
                startDate: day(2026, 9, 1),
                periodUnit: .week,
                timesPerPeriod: 4,
                periodCount: nil
            )
        )

        #expect(request.actionType == "PHYSICAL_ACTIVITY")
        #expect(request.periodUnit == "WEEK")
        #expect(request.startDate == "2026-09-01")
        #expect(request.timesPerPeriod == 4)
        #expect(request.periodCount == nil)
    }
}
