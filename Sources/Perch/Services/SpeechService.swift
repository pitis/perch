import AVFoundation
import Observation
import Speech

/// Dictation that stays on this Mac: `requiresOnDeviceRecognition` is set, and if on-device isn't available it
/// reports an error rather than quietly falling back to a server.
@Observable
final class SpeechService {
    /// Which mic button is listening, so only that one shows as active.
    private(set) var activeOwner: UUID?
    var errorText: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?

    func toggle(owner: UUID, onText: @escaping (String) -> Void) {
        if activeOwner == owner {
            stop()
        } else {
            stop()
            start(owner: owner, onText: onText)
        }
    }

    private func start(owner: UUID, onText: @escaping (String) -> Void) {
        errorText = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard status == .authorized, micGranted else {
                        self.errorText = "Allow Microphone and Speech Recognition for Perch in System Settings › Privacy & Security."
                        return
                    }
                    self.begin(owner: owner, onText: onText)
                }
            }
        }
    }

    private func onDeviceRecognizer() -> SFSpeechRecognizer? {
        let candidates = (Locale.preferredLanguages.first.map { [$0] } ?? []) + ["en-US"]
        for identifier in candidates {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                return recognizer
            }
        }
        return nil
    }

    private func begin(owner: UUID, onText: @escaping (String) -> Void) {
        guard let recognizer = onDeviceRecognizer() else {
            errorText = "On-device speech isn't ready. Turn on Dictation in System Settings › Keyboard so macOS downloads it."
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorText = "No microphone found."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        activeOwner = owner
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.activeOwner == owner else { return }
                if let result { onText(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
    }

    func stop() {
        guard activeOwner != nil || request != nil else { return }
        activeOwner = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }
}
