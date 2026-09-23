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
