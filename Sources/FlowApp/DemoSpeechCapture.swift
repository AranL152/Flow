import AVFoundation
import Speech
import Foundation
import Combine

/// Live on-device speech, separate from the cloud formatting stream. This path
/// never silently falls back to Apple's remote recognizer.
@MainActor
final class DemoSpeechCapture: ObservableObject {
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var epoch = UUID()
    private var drain: Task<Void, Never>?

    func start(onText: @escaping (String, Bool) -> Void, onLevel: @escaping (Float) -> Void,
               onError: @escaping (String) -> Void) async throws {
        cancel()
        let session = epoch
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw failure("Run the bundled Flow Demo app for microphone access. Typed input works here too.")
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard session == epoch, !Task.isCancelled else { throw CancellationError() }
        guard mic else { throw failure("Enable Flow Demo’s microphone access in System Settings, or type a message.") }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard session == epoch, !Task.isCancelled else { throw CancellationError() }
        guard authorization == .authorized else { throw failure("Enable Speech Recognition for Flow Demo in System Settings, or type a message.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw failure("On-device English recognition is unavailable on this Mac. Use typed input, or enable/download English dictation in System Settings.")
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { cancel(); throw failure("No microphone input is available.") }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let samples = buffer.floatChannelData?[0]
            let count = Int(buffer.frameLength)
            var square: Float = 0
            if let samples, count > 0 { for i in 0..<count { square += samples[i] * samples[i] } }
            let level = count > 0 ? min(1, sqrt(square / Float(count)) * 8) : 0
            Task { @MainActor [weak self] in
                guard self?.epoch == session else { return }; onLevel(level)
            }
        }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.epoch == session else { return }
                if let text { onText(text, final) }
                if final { self.cancel(); return }
                if let error { self.cancel(); onError(error.localizedDescription) }
            }
        }
        do { audio.prepare(); try audio.start() }
        catch { cancel(); throw error }
    }

    func stop() {
        audio.stop()
        if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        // Allow the recognizer to deliver its final revision before cancellation.
        drain = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }; self?.cancel()
        }
    }

    func cancel() {
        epoch = UUID(); drain?.cancel(); drain = nil
        audio.stop()
        if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "Flow.Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
