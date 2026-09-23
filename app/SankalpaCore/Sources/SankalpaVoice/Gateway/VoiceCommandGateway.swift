import Foundation
import SankalpaCore

@MainActor
public protocol VoiceCommandGateway: AnyObject {
    var voicePracticeSnapshot: VoicePracticeSnapshot { get }
    var voiceNow: CalendarMoment { get }

    func logSessionForVoice(
        _ id: SankalpaId,
        occurredAt: CalendarMoment,
        confirmingRapidRepeat: Bool
    ) async -> VoiceSessionExecution

    func undoSessionForVoice(_ receipt: VoiceSessionReceipt) async -> VoiceSessionUndoExecution

    func declareForVoice(
        _ declaration: Declaration,
        commandID: UUID
    ) async -> VoiceDeclarationExecution
}

public struct VoiceSessionReceipt: Equatable, Sendable {
    public let sessionId: SessionId
    public let sankalpaId: SankalpaId
    public let acceptedByService: Bool

    public init(sessionId: SessionId, sankalpaId: SankalpaId, acceptedByService: Bool) {
        self.sessionId = sessionId
        self.sankalpaId = sankalpaId
        self.acceptedByService = acceptedByService
    }
}

public enum VoiceSessionExecution: Equatable, Sendable {
    case acceptedByService(VoiceSessionReceipt)
    case pendingOnDevice(VoiceSessionReceipt)
    case rapidRepeatConfirmationRequired
    case refused(String)
    case notSaved(String)
}

public enum VoiceSessionUndoExecution: Equatable, Sendable {
    case removed
    case pendingOnDevice
    case refused(String)
}

public enum VoiceDeclarationExecution: Equatable, Sendable {
    case acceptedByService
    case serviceUnavailable(String)
    case refused(String)
    case notSaved(String)
}
