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
        occurredAt: CalendarMoment
    ) async -> VoiceSessionExecution {
        let result = await remote.logSessionWithDisposition(id, occurredAt: occurredAt)
        rebuild()
        switch result {
        case .acceptedByService: return .acceptedByService
        case .pendingOnDevice: return .pendingOnDevice
        case .refused(let error):
            if case .storage = error { return .notSaved(error.message) }
            return .refused(error.message)
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
