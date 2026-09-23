import Testing
@testable import SankalpaVoice

@Suite("Voice speech finalization")
struct SpeechFinalizationTests {
    @Test("Consumed audio is finalized before the analyzer is finished")
    func successfulFinalizationOrder() async throws {
        let analysis = RecordingAnalysis()

        try await finishVoiceAnalysis(analysis)

        #expect(await analysis.recordedSteps() == [.finalizeConsumedAudio, .finishImmediately])
    }

    @Test("The analyzer is still finished when finalization fails")
    func failureStillFinishesAnalyzer() async {
        let analysis = RecordingAnalysis(finalizationFails: true)
        var receivedExpectedError = false

        do {
            try await finishVoiceAnalysis(analysis)
        } catch is ExpectedFinalizationError {
            receivedExpectedError = true
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(receivedExpectedError)
        #expect(await analysis.recordedSteps() == [.finalizeConsumedAudio, .finishImmediately])
    }
}

private enum FinalizationStep: Equatable, Sendable {
    case finalizeConsumedAudio
    case finishImmediately
}

private struct ExpectedFinalizationError: Error {}

private actor RecordingAnalysis: VoiceAnalysisFinishing {
    private let finalizationFails: Bool
    private var steps: [FinalizationStep] = []

    init(finalizationFails: Bool = false) {
        self.finalizationFails = finalizationFails
    }

    func finalizeConsumedAudio() throws {
        steps.append(.finalizeConsumedAudio)
        if finalizationFails { throw ExpectedFinalizationError() }
    }

    func finishImmediately() {
        steps.append(.finishImmediately)
    }

    func recordedSteps() -> [FinalizationStep] { steps }
}
