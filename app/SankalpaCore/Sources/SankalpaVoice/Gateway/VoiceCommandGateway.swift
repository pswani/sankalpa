import SankalpaCore

@MainActor
public protocol VoiceCommandGateway: AnyObject {
    var voicePracticeSnapshot: VoicePracticeSnapshot { get }
    var voiceNow: CalendarMoment { get }

    func logSessionForVoice(
        _ id: SankalpaId,
        occurredAt: CalendarMoment
    ) async -> VoiceSessionExecution

    func declareForVoice(_ declaration: Declaration) async -> VoiceDeclarationExecution
}

public enum VoiceSessionExecution: Equatable, Sendable {
    case acceptedByService
    case pendingOnDevice
    case refused(String)
    case notSaved(String)
}

public enum VoiceDeclarationExecution: Equatable, Sendable {
    case acceptedByService
    case serviceUnavailable(String)
    case refused(String)
    case notSaved(String)
}
