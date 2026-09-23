import Foundation

public struct VoiceTranscriptUpdate: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public protocol VoiceTranscribing: Sendable {
    func start(locale: Locale) async throws -> AsyncThrowingStream<VoiceTranscriptUpdate, Error>
    func finish() async throws -> String
    func cancel() async
}

public enum VoiceTranscriptionError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case permissionDenied
    case unsupportedLocale
    case alreadyListening
    case noFinalTranscript
}

/// Builds the visible utterance from finalized segments plus the current replaceable segment.
struct VoiceTranscriptAccumulator: Sendable, Equatable {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String { Self.join(finalizedText, volatileText) }

    mutating func receive(_ text: String, isFinal: Bool) -> String {
        if isFinal {
            finalizedText = Self.join(finalizedText, text)
            volatileText = ""
        } else {
            volatileText = text
        }
        return self.text
    }

    private static func join(_ leading: String, _ trailing: String) -> String {
        let leading = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if leading.isEmpty { return trailing }
        if trailing.isEmpty { return leading }
        return "\(leading) \(trailing)"
    }
}

/// The small shutdown boundary used by the live adapter. Keeping the sequencing here makes the
/// important guarantee testable without requiring a microphone or Speech framework model.
protocol VoiceAnalysisFinishing: Sendable {
    func finalizeConsumedAudio() async throws
    func finishImmediately() async
}

func finishVoiceAnalysis(_ analysis: any VoiceAnalysisFinishing) async throws {
    do {
        try await analysis.finalizeConsumedAudio()
    } catch {
        await analysis.finishImmediately()
        throw error
    }
    await analysis.finishImmediately()
}
