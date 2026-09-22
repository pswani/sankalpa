import Testing
@testable import SankalpaCore

/// The edges of what may be declared.
///
/// The existing suites check that zero and negative values are refused. These are the other end:
/// the largest value each rule allows, and the first one it does not. A limit that is never
/// tested at its boundary is a limit that can drift by one without anything noticing — and the
/// declare form shows these numbers to the user, so an off-by-one here is visible.
@Suite("Declaration bounds")
struct DeclarationBoundsTests {

    @Test("A title of exactly the maximum length is accepted, one character more is not")
    func titleLength() throws {
        let longest = String(repeating: "a", count: Title.maxLength)
        #expect(try Title(longest).value.count == Title.maxLength)

        #expect(throws: DeclarationError.invalidTitle(.tooLong(max: Title.maxLength))) {
            try Title(longest + "a")
        }
    }

    /// The length that counts is the trimmed one, because trimming is what is stored. A title
    /// padded past the limit with spaces is a title the user typed inside it.
    @Test("A title is measured after trimming, not before")
    func titleTrimming() throws {
        let padded = "   " + String(repeating: "a", count: Title.maxLength) + "   "
        #expect(try Title(padded).value.count == Title.maxLength)
        #expect(try Title("  Vipassana \n ").value == "Vipassana")
    }

    @Test("Whitespace alone is not a title")
    func blankTitle() {
        #expect(throws: DeclarationError.invalidTitle(.blank)) { try Title(" \n\t ") }
        #expect(throws: DeclarationError.invalidTitle(.blank)) { try Title("") }
    }

    @Test("The most times per period that can be committed to is accepted; one more is refused")
    func timesPerPeriodCeiling() throws {
        #expect(try TimesPerPeriod(TimesPerPeriod.maxValue).value == TimesPerPeriod.maxValue)
        #expect(throws: DeclarationError.invalidTimesPerPeriod(TimesPerPeriod.maxValue + 1)) {
            try TimesPerPeriod(TimesPerPeriod.maxValue + 1)
        }
    }

    @Test("The longest duration is accepted; one period more is refused")
    func periodCountCeiling() throws {
        #expect(try PeriodCount(PeriodCount.maxValue).value == PeriodCount.maxValue)
        #expect(throws: DeclarationError.invalidPeriodCount(PeriodCount.maxValue + 1)) {
            try PeriodCount(PeriodCount.maxValue + 1)
        }
    }

    /// The two refusals read differently at each end — "at least one" against "the most that can
    /// be committed to" — and the user sees the sentence, not the enum.
    @Test("Exceeding a ceiling and falling below a floor are worded differently")
    func boundsAreWordedForTheEndTheyCameFrom() {
        let tooFew = DeclarationError.invalidTimesPerPeriod(0)
        let tooMany = DeclarationError.invalidTimesPerPeriod(TimesPerPeriod.maxValue + 1)
        #expect(tooFew.message != tooMany.message)
        #expect(tooMany.message.contains("\(TimesPerPeriod.maxValue)"))

        let tooShort = DeclarationError.invalidPeriodCount(0)
        let tooLong = DeclarationError.invalidPeriodCount(PeriodCount.maxValue + 1)
        #expect(tooShort.message != tooLong.message)
        #expect(tooLong.message.contains("\(PeriodCount.maxValue)"))
    }

    /// A description is optional, so the only rule is that it is normalised — and that a
    /// description of nothing but spaces is reported as absent rather than rendering an empty row.
    @Test("A description is trimmed, and whitespace alone counts as none")
    func descriptionNormalisation() {
        #expect(SankalpaDescription("  two sittings a day  ").value == "two sittings a day")
        #expect(SankalpaDescription("   \n ").isEmpty)
        #expect(SankalpaDescription("").isEmpty)
    }

    /// The bounds hold through the real entry point too, not only on the value objects.
    @Test("Declaring through the service enforces the same bounds")
    func serviceEnforcesTheSameBounds() {
        let environment = TestEnvironment(today: moment(2026, 3, 10))

        #expect(throws: SankalpaCommandError.self) {
            try environment.service.declareSankalpa(
                Declaration(
                    title: String(repeating: "a", count: Title.maxLength + 1),
                    actionType: .meditation,
                    startDate: day(2026, 3, 10),
                    periodUnit: .day,
                    timesPerPeriod: 1
                )
            )
        }
        #expect(throws: SankalpaCommandError.self) {
            try environment.service.declareSankalpa(
                Declaration(
                    title: "Too often",
                    actionType: .meditation,
                    startDate: day(2026, 3, 10),
                    periodUnit: .day,
                    timesPerPeriod: TimesPerPeriod.maxValue + 1
                )
            )
        }
        #expect(throws: SankalpaCommandError.self) {
            try environment.service.declareSankalpa(
                Declaration(
                    title: "Too long",
                    actionType: .meditation,
                    startDate: day(2026, 3, 10),
                    periodUnit: .day,
                    timesPerPeriod: 1,
                    periodCount: PeriodCount.maxValue + 1
                )
            )
        }
        // Nothing partially valid was stored on the way out.
        #expect(environment.sankalpas.all().isEmpty)
    }
}
