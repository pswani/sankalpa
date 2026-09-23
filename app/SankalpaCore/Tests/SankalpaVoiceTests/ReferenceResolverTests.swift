import Foundation
import Testing
@testable import SankalpaVoice
@testable import SankalpaCore

@Suite("Voice reference resolver")
struct ReferenceResolverTests {
    private let resolver = SankalpaReferenceResolver()
    private let vipassana = VoiceSankalpaReference(id: SankalpaId(), title: "Morning Vipassana")
    private let kriya = VoiceSankalpaReference(id: SankalpaId(), title: "Sudarshan Kriya")

    @Test("Exact matching ignores case, punctuation, whitespace and diacritics")
    func normalizedExactMatch() {
        let accented = VoiceSankalpaReference(id: SankalpaId(), title: "Café Walk")
        let result = resolver.resolve("  CAFE—walk! ", among: [accented])
        #expect(result == .one(accented))
    }

    @Test("A unique whole-word title reference resolves")
    func wholeWordMatch() {
        #expect(resolver.resolve("vipassana", among: [vipassana, kriya]) == .one(vipassana))
    }

    @Test("Partial words do not resolve")
    func noSubstringMatch() {
        #expect(resolver.resolve("pass", among: [vipassana, kriya]) == .none)
    }

    @Test("Only the highest matching tier participates")
    func exactOutranksContainment() {
        let exact = VoiceSankalpaReference(id: SankalpaId(), title: "Walk")
        let longer = VoiceSankalpaReference(id: SankalpaId(), title: "Evening Walk")
        #expect(resolver.resolve("walk", among: [exact, longer]) == .one(exact))
    }

    @Test("Multiple matches stay ambiguous")
    func ambiguousMatch() {
        let morning = VoiceSankalpaReference(id: SankalpaId(), title: "Morning Walk")
        let evening = VoiceSankalpaReference(id: SankalpaId(), title: "Evening Walk")
        #expect(resolver.resolve("walk", among: [morning, evening]) == .ambiguous([morning, evening]))
    }
}
