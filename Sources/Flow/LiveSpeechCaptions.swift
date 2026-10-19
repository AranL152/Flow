import AVFoundation
import Foundation
import Speech

/// Partial, on-device recognition of the same audio used by final dictation.
/// No second microphone stream, formatting, or remote recognition fallback.
@MainActor
public final class LiveSpeechCaptions {
    public var onText: ((String, Bool) -> Void)?
    public var onStatus: ((String) -> Void)?
    public private(set) var isListening = false
    public private(set) var finalizedText: String?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var drain: Task<Void, Never>?
    private var generation = UUID()
    private var offset: UInt64 = 0

    public init() {}

    public func start() async {
        cancel()
        let session = generation
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            onStatus?("Live captions need the bundled Flow app.")
            return
        }
        onStatus?("Preparing live captions…")
        // Recording/replay must never initiate another permission dialog.
        // Access is requested only from the explicit Settings action below.
        let authorization = SFSpeechRecognizer.authorizationStatus()
        guard session == generation, !Task.isCancelled else { return }
        guard authorization == .authorized else {
            onStatus?(Self.permissionMessage)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            onStatus?("On-device captions aren’t available for this language on this Mac.")
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        self.request = request
        isListening = true
        onStatus?("Listening…")
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.generation == session else { return }
                if final { self.finalizedText = text }
                if let text { self.onText?(text, final) }
                if final {
                    self.isListening = false
                    self.onStatus?("Live transcript")
                } else if let error {
                    self.isListening = false
                    self.onStatus?("Live captions stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    public static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    public static var canRequestPermission: Bool { SFSpeechRecognizer.authorizationStatus() == .notDetermined }

    public static var permissionMessage: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "Speech recognition is enabled."
        case .notDetermined: return "Enable speech recognition in Flow → Settings → General for live captions."
        case .denied: return "Allow Flow in System Settings → Privacy & Security → Speech Recognition."
        case .restricted: return "Speech recognition is restricted by this Mac’s settings."
        @unknown default: return "Check Speech Recognition access in System Settings."
        }
    }

    /// Call only in direct response to the user's Enable action.
    public static func requestPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Audio fixtures use this same recognition path without a second microphone.
    public func append(samples: [Float], sampleRate: UInt32) {
        guard isListening, !samples.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input in
            if let base = input.baseAddress { channel.update(from: base, count: input.count) }
        }
        request?.append(buffer)
    }

    public func feed(from engine: Flow) {
        guard isListening else { return }
        for _ in 0..<8 {
            let chunk = engine.recordingSamples(after: offset)
            guard !chunk.frames.isEmpty else { break }
            append(samples: chunk.frames, sampleRate: chunk.sampleRate)
            offset = chunk.nextOffset
        }
    }

    public func finish(from engine: Flow? = nil) {
        guard isListening else { cancel(); return }
        if let engine { feed(from: engine) }
        request?.endAudio()
        let session = generation
        drain = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.generation == session else { return }
            self.cancel()
        }
    }

    public func cancel() {
        generation = UUID()
        drain?.cancel(); drain = nil
        request?.endAudio(); recognition?.cancel()
        recognition = nil; request = nil; recognizer = nil
        isListening = false; finalizedText = nil; offset = 0
    }
}
