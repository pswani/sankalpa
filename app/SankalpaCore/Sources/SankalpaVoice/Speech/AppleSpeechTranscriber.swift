import AVFoundation
import Foundation
import Speech

/// A single-use, in-memory speech pipeline. No audio file is created at any point.
@available(iOS 27.0, macOS 27.0, *)
public actor AppleSpeechTranscriber: VoiceTranscribing {
    private var analyzer: SpeechAnalyzer?
    private var provider: CaptureInputSequenceProvider?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<VoiceTranscriptUpdate, Error>.Continuation?
    private var transcript = VoiceTranscriptAccumulator()

    public init() {}

    public func start(
        locale: Locale
    ) async throws -> AsyncThrowingStream<VoiceTranscriptUpdate, Error> {
        guard analyzer == nil else { throw VoiceTranscriptionError.alreadyListening }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw VoiceTranscriptionError.permissionDenied
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceTranscriptionError.unsupportedLocale
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw VoiceTranscriptionError.microphoneUnavailable
        }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let provider = try await CaptureInputSequenceProvider.providerWithSession(
            from: microphone,
            compatibleWith: [transcriber]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputs = provider.analyzerInputs
        let pair = AsyncThrowingStream<VoiceTranscriptUpdate, Error>.makeStream()

        self.analyzer = analyzer
        self.provider = provider
        self.continuation = pair.continuation
        self.transcript = VoiceTranscriptAccumulator()

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await self?.received(text: text, isFinal: result.isFinal)
                }
            } catch {
                await self?.failed(error)
            }
        }
        analysisTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputs)
            } catch {
                await self?.failed(error)
            }
        }
        provider.captureSession.startRunning()
        return pair.stream
    }

    public func finish() async throws -> String {
        guard let analyzer else { throw VoiceTranscriptionError.noFinalTranscript }
        provider?.captureSession.stopRunning()

        // CaptureInputSequenceProvider owns an open-ended input sequence. Stopping its capture
        // session stops new buffers, but does not guarantee that the sequence terminates.
        // finalizeAndFinishThroughEndOfInput() would therefore be allowed to wait forever.
        // Finalize everything the analyzer has consumed, then explicitly finish the session so
        // the module result stream terminates.
        try await finishVoiceAnalysis(AppleSpeechAnalysisFinisher(analyzer: analyzer))
        await resultTask?.value
        let text = transcript.text
        releasePipeline()
        guard !text.isEmpty else { throw VoiceTranscriptionError.noFinalTranscript }
        return text
    }

    public func cancel() async {
        provider?.captureSession.stopRunning()
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        analysisTask?.cancel()
        continuation?.finish()
        releasePipeline()
    }

    private func received(text: String, isFinal: Bool) {
        let combined = transcript.receive(text, isFinal: isFinal)
        continuation?.yield(VoiceTranscriptUpdate(text: combined, isFinal: isFinal))
    }

    private func failed(_ error: Error) {
        provider?.captureSession.stopRunning()
        continuation?.finish(throwing: error)
    }

    private func releasePipeline() {
        continuation?.finish()
        continuation = nil
        resultTask = nil
        analysisTask = nil
        provider = nil
        analyzer = nil
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct AppleSpeechAnalysisFinisher: VoiceAnalysisFinishing {
    let analyzer: SpeechAnalyzer

    func finalizeConsumedAudio() async throws {
        try await analyzer.finalize(through: nil)
    }

    func finishImmediately() async {
        await analyzer.cancelAndFinishNow()
    }
}
