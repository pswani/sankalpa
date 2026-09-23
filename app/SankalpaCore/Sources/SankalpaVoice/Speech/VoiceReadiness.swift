import AVFAudio
import Foundation
import FoundationModels
import Speech

public enum VoiceReadinessStatus: Equatable, Sendable {
    case ready
    case unavailable(VoiceUnavailableReason)
}

public struct VoiceReadiness: Sendable {
    public init() {}

    public func status(locale: Locale = .current) async -> VoiceReadinessStatus {
        guard #available(iOS 27.0, macOS 27.0, *) else {
            return .unavailable(.unsupportedOS)
        }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .unavailable(.microphonePermissionNeeded)
        case .denied: return .unavailable(.microphoneDenied)
        case .granted: break
        @unknown default: return .unavailable(.microphoneDenied)
        }

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unavailable(.unsupportedLocale)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            return .unavailable(.speechAssetsNeeded)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            guard SystemLanguageModel.default.supportsLocale(locale) else {
                return .unavailable(.unsupportedLocale)
            }
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.languageModelDisabled)
        case .unavailable(.modelNotReady), .unavailable(.deviceNotEligible):
            return .unavailable(.languageModelNotReady)
        case .unavailable:
            return .unavailable(.languageModelNotReady)
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    public func installSpeechAssets(locale: Locale = .current) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceTranscriptionError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }
    }
}
