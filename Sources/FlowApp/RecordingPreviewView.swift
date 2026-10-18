import AppKit
import AVFoundation
import Flow
import SwiftUI

/// Isolated verification of the real recording components. Never installs
/// hotkeys, opens production data, pastes, or records microphone audio.
struct RecordingPreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var running = false
    @State private var report = ""
    @State private var captions = LiveSpeechCaptions()
    @State private var events: [[String: Any]] = []
    @State private var levels: [Float] = []
    @State private var started = Date()
    @State private var audioStartedAt: Double?
    @State private var audioFinishedAt: Double?

    @MainActor
    private func snapshot(_ stage: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--verification-snapshot"), arguments.indices.contains(index + 1),
              let view = NSApp.windows.first(where: { $0.title == "Flow Recording Verification" })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: arguments[index + 1] + "-" + stage + ".png"), options: .atomic)
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Recording UI verification").font(.title2.weight(.semibold))
            Text("Isolated preview · simulated input is labelled below")
                .font(.caption).foregroundStyle(.secondary)
            RecordingIndicatorView()
                .environmentObject(appState)
                .frame(width: 500, height: 150)
            WaveformView(isRecording: appState.isRecording, audioLevel: appState.smoothedAudioLevel)
                .frame(width: 300, height: 60)
            Text(report.isEmpty ? "Ready" : report)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("recording-verification-status")
            Button("Replay verification") { Task { await run() } }.disabled(running)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FW.background)
        .task { await run() }
        .onDisappear { captions.cancel() }
    }

    @MainActor
    private func run() async {
        guard !running else { return }
        running = true; events = []; levels = []; started = Date()
        audioStartedAt = nil; audioFinishedAt = nil
        appState.liveTranscript = ""; appState.isProcessing = false
        appState.isRecording = true; appState.recordingDuration = 0
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--speech-fixture"), arguments.indices.contains(index + 1) {
            report = "Recognizing a generated speech fixture through the real on-device recognizer"
            captions.onText = { text, final in
                appState.liveTranscript = text
                events.append(["text": text, "final": final, "seconds": Date().timeIntervalSince(started)])
                if events.count == 4 || final {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        snapshot("speech")
                    }
                }
            }
            captions.onStatus = { status in appState.liveCaptionStatus = status; report = status }
            await captions.start()
            if captions.isListening {
                do {
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[index + 1]))
                    let rate = file.processingFormat.sampleRate
                    audioStartedAt = Date().timeIntervalSince(started)
                    while file.framePosition < file.length && !Task.isCancelled {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 20)) else { break }
                        try file.read(into: buffer)
                        guard let channel = buffer.floatChannelData?[0] else { break }
                        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                        captions.append(samples: samples, sampleRate: UInt32(rate))
                        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
                        tick(level: min(1, rms * 3))
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    audioFinishedAt = Date().timeIntervalSince(started)
                    captions.finish()
                    try await Task.sleep(for: .seconds(2.2))
                    report = events.isEmpty ? "FAILED: recognizer returned no text" : "Audio fixture completed · \(events.count) recognition updates"
                } catch { report = "FAILED: \(error.localizedDescription)" }
            } else { report = "UNAVAILABLE: \(appState.liveCaptionStatus)" }
        } else {
            report = "Simulated captions and measured-level sequence · UI verification only"
            appState.liveCaptionStatus = "Simulated input"
            let words = "Can you check the slides tomorrow".split(separator: " ")
            for step in 0..<150 {
                let speaking = step < 105
                let level: Float = speaking ? Float(0.025 + 0.18 * pow(sin(Double(step) * 0.13), 2)) : 0
                tick(level: level)
                if speaking { appState.liveTranscript = words.prefix(min(words.count, step / 15 + 1)).joined(separator: " ") }
                if step == 65 { snapshot("speaking") }
                if step == 149 { snapshot("silence") }
                try? await Task.sleep(for: .seconds(1.0 / 30.0))
            }
        }
        appState.isRecording = false; appState.smoothedAudioLevel = 0
        appState.isProcessing = true
        try? await Task.sleep(for: .milliseconds(100))
        snapshot("processing")
        try? await Task.sleep(for: .milliseconds(600))
        appState.isProcessing = false; captions.cancel(); running = false
        if let index = arguments.firstIndex(of: "--verification-report"), arguments.indices.contains(index + 1) {
            let json: [String: Any] = ["status": report, "events": events, "peak_level": levels.max() ?? 0,
                "final_text": appState.liveTranscript, "frame_updates": levels.count,
                "recording": appState.isRecording, "processing": appState.isProcessing,
                "audio_started_seconds": audioStartedAt as Any? ?? NSNull(),
                "audio_finished_seconds": audioFinishedAt as Any? ?? NSNull(),
                "source": arguments.contains("--speech-fixture") ? "generated audio through on-device recognition" : "simulated UI input"]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            }
        }
    }

    @MainActor
    private func tick(level: Float) {
        appState.smoothedAudioLevel = level; appState.audioLevel = level
        appState.recordingDuration = UInt64(Date().timeIntervalSince(started) * 1000)
        levels.append(level)
    }
}
