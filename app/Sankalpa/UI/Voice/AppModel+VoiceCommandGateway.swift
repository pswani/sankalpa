import Foundation
import SankalpaCore
import SankalpaVoice

extension AppModel: VoiceCommandGateway {
    var voicePracticeSnapshot: VoicePracticeSnapshot {
        VoicePracticeSnapshot(
            sankalpas: summaries.map {
                VoiceSankalpaReference(id: $0.id, title: $0.title)
            },
            hasLoadedPractice: remote.hasLoaded,
            latestRefreshReachedService: remote.refreshFailure == nil && !remote.isShowingCachedPractice
        )
    }

    var voiceNow: CalendarMoment { remote.now() }

    func logSessionForVoice(
        _ id: SankalpaId,
        occurredAt: CalendarMoment,
        confirmingRapidRepeat: Bool
    ) async -> VoiceSessionExecution {
        let result = await logSession(
            id, occurredAt: occurredAt, confirmingRapidRepeat: confirmingRapidRepeat
        )
        switch result {
        case .logged(let receipt):
            let voiceReceipt = VoiceSessionReceipt(
                sessionId: receipt.sessionId,
                sankalpaId: receipt.sankalpaId,
                acceptedByService: receipt.delivery == .accepted
            )
            return receipt.delivery == .accepted
                ? .acceptedByService(voiceReceipt)
                : .pendingOnDevice(voiceReceipt)
        case .rapidRepeatConfirmationRequired:
            // Voice owns its review surface, so do not also open the global touch dialog.
            cancelRapidRepeat()
            return .rapidRepeatConfirmationRequired
        case .alreadyInProgress:
            return .notSaved("That session is still being logged.")
        case .refused(let error):
            if case .storage = error { return .notSaved(error.message) }
            return .refused(error.message)
        }
    }

    func undoSessionForVoice(
        _ receipt: VoiceSessionReceipt
    ) async -> VoiceSessionUndoExecution {
        let result = await remote.deleteSession(
            receipt.sankalpaId,
            sessionId: receipt.sessionId,
            knownToBeOnServer: receipt.acceptedByService
        )
        rebuild()
        clearUndoReceipt()
        switch result {
        case .removed: return .removed
        case .pendingOnDevice: return .pendingOnDevice
        case .refused(let error): return .refused(error.message)
        }
    }

    func declareForVoice(
        _ declaration: Declaration,
        commandID: UUID
    ) async -> VoiceDeclarationExecution {
        if let error = await remote.declare(declaration, id: SankalpaId(commandID)) {
            if case .storage = error { return .serviceUnavailable(error.message) }
            return .refused(error.message)
        }
        rebuild()
        return .acceptedByService
    }
}
