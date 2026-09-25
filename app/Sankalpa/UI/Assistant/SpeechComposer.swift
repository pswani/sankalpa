import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechComposer {
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isStarting = false
    private var hasInputTap = false
    private var generation = 0
    private(set) var isListening = false
    private(set) var message: String?
    var transcript = ""

    init() {
        // Speech callbacks update observable UI state, so make their delivery queue explicit.
        recognizer?.queue = .main
    }

    func toggle() {
        if isListening || isStarting {
            stop()
        } else {
            isStarting = true
            Task { await start() }
        }
    }

    func start() async {
        generation += 1
        let activeGeneration = generation
        let speech = await Self.speechAuthorization()
        guard isStarting, generation == activeGeneration else { return }
        guard speech == .authorized else {
            isStarting = false
            message = "Speech recognition permission is required."
            return
        }
        guard await microphonePermission() else {
            isStarting = false
            message = "Microphone permission is required."
            return
        }
        guard isStarting, generation == activeGeneration else { return }
        guard recognizer?.supportsOnDeviceRecognition == true else {
            isStarting = false
            message = "On-device speech recognition is not available on this device."
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            Self.installInputTap(on: input, format: format, request: request)
            hasInputTap = true
            engine.prepare()
            try engine.start()
            isStarting = false
            isListening = true
            message = nil
            task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.generation == activeGeneration, self.isListening else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil { self.stop() }
                }
            }
        } catch { stop(); message = "Speech recognition could not start." }
    }

    func stop() {
        generation += 1
        isStarting = false
        if engine.isRunning { engine.stop() }
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        // The transcript deliberately remains in the editable composer. It is never submitted here.
    }

    private func microphonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    // Speech authorization and audio-tap callbacks are invoked by Apple frameworks on
    // background queues. Defining these closures outside MainActor isolation prevents Swift 6
    // from attaching a main-executor precondition to callbacks that aren't delivered there.
    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func installInputTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }
}
