import Testing
@testable import SankalpaVoice

@Suite("Voice transcript accumulation")
struct TranscriptAccumulatorTests {
    @Test("Volatile text is replaced without duplicating earlier words")
    func volatileTextIsReplaced() {
        var transcript = VoiceTranscriptAccumulator()

        #expect(transcript.receive("I went", isFinal: false) == "I went")
        #expect(transcript.receive("I went to the gym", isFinal: false) == "I went to the gym")
    }

    @Test("Final segments are retained while the next segment changes")
    func finalSegmentsAreRetained() {
        var transcript = VoiceTranscriptAccumulator()

        #expect(transcript.receive("I went to the gym", isFinal: true) == "I went to the gym")
        #expect(transcript.receive("yesterday", isFinal: false) == "I went to the gym yesterday")
        #expect(transcript.receive("yesterday afternoon", isFinal: true)
            == "I went to the gym yesterday afternoon")
        #expect(transcript.text == "I went to the gym yesterday afternoon")
    }
}
