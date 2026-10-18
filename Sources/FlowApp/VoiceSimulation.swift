import AppKit
import AVFoundation
import Flow
import SwiftUI

/// Audible fixtures run through Apple's live recognizer and the normal Rust
/// audio → Whisper → streamed formatting → final-text learning pipeline.
@MainActor
final class VoiceSimulationModel: ObservableObject {
    @Published var running = false
    @Published var stage = "Ready to simulate voice input"
    @Published var draft = ""
    @Published var sent = ""
    @Published var memory = ""
    @Published var error: String?
    @Published var finished = false
    @Published var readableStreaming = true
    @Published var draftPhase = "Waiting for voice"
    @Published var canSend = false
    @Published var chunkCount = 0
    let state: AppState
    private let captions = LiveSpeechCaptions()
    private var player: AVAudioPlayer?
    private var indicator: RecordingIndicatorWindow?
    private var task: Task<Void, Never>?
    private var events: [[String: Any]] = []
    private var started = Date()

    init(state: AppState) { self.state = state }

    func start() {
        guard !running else { return }
        running = true; finished = false; error = nil
        task = Task {
            do {
                _ = state.engine.resetStyleLearning()
                sent = ""; memory = ""; canSend = false; events = []; started = Date()
                state.currentApp = "Messages"; state.targetAppName = "Messages · Alex (simulation)"
                state.lastTranscription = nil; state.liveTranscript = ""; state.streamedOutput = ""
                stage = "1 / 3 · Generated voice → real captions and model output"
                try await take(name: "first")
                try await Task.sleep(for: .seconds(1.5))
                stage = "2 / 3 · Simulated user edit: “slides” → “deck”, then Send"
                let correction = "yo can u check the deck tomorrow?"
                // This is an explicitly labelled scripted edit, never fabricated
                // model output. Sending here updates only the in-memory fixture.
                draft = correction
                note("simulated_edit", text: correction)
                try await Task.sleep(for: .seconds(1.5))
                state.engine.recordFinalText(correction)
                canSend = false
                guard state.engine.styleStats?.edited == 1 else { throw failure("The edited example was not saved") }
                sent = correction; draft = ""
                memory = "Saved one edited example for Alex · slides → deck"
                note("learning_saved", text: correction)
                try await Task.sleep(for: .seconds(1.5))
                stage = "3 / 3 · New voice input → model uses Alex’s saved example"
                try await take(name: "second")
                stage = "Finished · Replay, or edit the draft and use Simulated Send"
                finished = true
                saveReport(status: "passed")
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; stage = "Simulation stopped"; saveReport(status: "failed") }
            }
            captions.cancel(); player?.stop(); indicator?.hide()
            state.isRecording = false; state.isProcessing = false; state.isStreamingOutput = false
            running = false
        }
    }

    func stop() { task?.cancel(); captions.cancel(); player?.stop(); indicator?.hide(); state.engine.discardPendingDictation() }

    func simulatedSend() {
        guard !running, canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.engine.recordFinalText(draft)
        canSend = false
        sent = draft; draft = ""
        memory = "Saved \(state.engine.styleStats?.examples ?? 0) examples for Alex"
        stage = "Your draft was saved to this isolated conversation · no real message sent"
    }

    private func take(name: String) async throws {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--simulation-audio-dir"), args.indices.contains(index + 1) else { throw failure("Missing generated audio fixtures") }
        let folder = URL(fileURLWithPath: args[index + 1])
        let audioURL = folder.appendingPathComponent(name + ".aiff")
        let pcmURL = folder.appendingPathComponent(name + ".pcm")
        let pcm = try Data(contentsOf: pcmURL)
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        draft = ""; draftPhase = "Live speech preview"; canSend = false; chunkCount = 0; state.liveTranscript = ""; state.streamedOutput = ""; state.isStreamingOutput = false
        state.isRecording = true; state.isProcessing = false; state.recordingDuration = 0
        captions.onText = { [weak self] text, final in
            self?.state.liveTranscript = text
            if self?.state.isRecording == true { self?.draft = text; self?.note("speech_preview_presented", text: text) }
            self?.note(final ? "caption_final" : "caption_partial", text: text)
        }
        captions.onStatus = { [weak self] status in self?.state.liveCaptionStatus = status }
        await captions.start()
        guard captions.isListening else { throw failure(state.liveCaptionStatus) }
        if indicator == nil { indicator = RecordingIndicatorWindow(appState: state) }
        indicator?.show()
        player = try AVAudioPlayer(contentsOf: audioURL)
        player?.prepareToPlay(); player?.play()
        let audioStart = Date()
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 30)) else { throw failure("Could not read the speech fixture") }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw failure("Expected mono float audio") }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            captions.append(samples: samples, sampleRate: UInt32(rate))
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count)))
            state.audioLevel = min(1, rms * 3); state.smoothedAudioLevel = state.audioLevel
            state.recordingDuration = UInt64(Date().timeIntervalSince(audioStart) * 1000)
            let due = Double(file.framePosition) / rate - Date().timeIntervalSince(audioStart)
            if due > 0 { try await Task.sleep(for: .seconds(due)) }
        }
        captions.finish()
        state.isRecording = false; state.audioLevel = 0; state.smoothedAudioLevel = 0; state.isProcessing = true
        note("audio_finished", text: name)
        draftPhase = "Speech preview · waiting for the model"
        var gotCompletion = false
        // Receive independently from presentation, so recorded receipt times
        // retain actual model latency when readable playback is enabled.
        let queue = AsyncThrowingStream<DictationStreamEvent, Error>.makeStream()
        let producer = Task {
            do {
                for try await event in state.engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: "Alex") {
                    try Task.checkCancellation()
                    switch event {
                    case .delta(let text): note("model_delta_received", text: text)
                    case .completed(let text): note("model_complete_received", text: text)
                    }
                    queue.continuation.yield(event)
                }
                queue.continuation.finish()
            } catch { queue.continuation.finish(throwing: error) }
        }
        defer { producer.cancel() }
        for try await event in queue.stream {
            try Task.checkCancellation()
            switch event {
            case .delta(let delta):
                state.isStreamingOutput = true; state.streamedOutput += delta
                draft = state.streamedOutput; chunkCount += 1
                draftPhase = readableStreaming ? "LLM draft · readable playback" : "LLM draft · live stream"
                note("model_delta_presented", text: delta)
                note("model_draft_presented", text: draft)
                if readableStreaming { try await Task.sleep(for: .milliseconds(180)) }
            case .completed(let text):
                state.lastTranscription = text; state.streamedOutput = text; draft = text
                gotCompletion = true; canSend = true; draftPhase = "LLM draft · ready to send"
                note("model_complete_presented", text: text)
            }
        }
        guard gotCompletion else { throw failure("The model stream did not complete") }
        state.isProcessing = false; state.isStreamingOutput = false
        state.refreshHistory()
        indicator?.hide(); captions.cancel()
    }

    private func note(_ kind: String, text: String) { events.append(["event": kind, "text": text, "seconds": Date().timeIntervalSince(started)]) }
    private func failure(_ message: String) -> NSError { NSError(domain: "Flow.Simulation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func saveReport(status: String) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--verification-report"), args.indices.contains(index + 1) else { return }
        let result: [String: Any] = ["status": status, "error": error ?? "", "events": events,
            "edited_examples": state.engine.styleStats?.edited ?? 0, "final_draft": draft,
            "used_learned_word": draft.localizedCaseInsensitiveContains("deck"),
            "readable_playback": readableStreaming, "presentation_delay_per_chunk_ms": readableStreaming ? 180 : 0,
            "scope": "isolated native simulation; generated speech; scripted edit and local send; actual Rust/cloud pipeline; no Messages AX insertion"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
    }
}

struct VoiceSimulationView: View {
    @ObservedObject var model: VoiceSimulationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flow · live voice simulation").font(.headline)
                    Text("Generated speech · real recognition and model tokens · isolated conversation")
                        .font(.caption).foregroundStyle(FW.textSecondary)
                }
                Spacer()
                Button(model.running ? "Running…" : "Replay simulation") { model.start() }.disabled(model.running)
            }.padding(18).background(FW.surface)
            Divider()
            HStack(spacing: 0) {
                RecordView().environmentObject(model.state).frame(minWidth: 560)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Label("Alex", systemImage: "person.crop.circle.fill").font(.title2.weight(.semibold))
                    Text("Simulated conversation · Project review").font(.caption).foregroundStyle(FW.textMuted)
                    Divider()
                    Text(model.stage).font(.subheadline.weight(.medium))
                    if !model.sent.isEmpty {
                        Text(model.sent).padding(14).frame(maxWidth: .infinity, alignment: .trailing)
                            .background(FW.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                        Text("Simulated Send · saved in Rust").font(.caption).foregroundStyle(FW.textMuted)
                    }
                    if !model.memory.isEmpty {
                        Label(model.memory, systemImage: "brain.head.profile")
                            .font(.caption).foregroundStyle(FW.accent).padding(12).fwSection()
                    }
                    Spacer()
                    if let error = model.error { Text(error).foregroundStyle(FW.danger).font(.caption) }
                    Toggle("Readable playback", isOn: $model.readableStreaming).disabled(model.running)
                        .font(.caption)
                    Text("Received model chunks are displayed 180 ms apart. Turn off for their actual arrival speed.")
                        .font(.caption2).foregroundStyle(FW.textMuted)
                    HStack {
                        Text(model.draftPhase)
                        Spacer()
                        if model.chunkCount > 0 { Text("\(model.chunkCount) chunks") }
                    }.font(.caption).foregroundStyle(FW.textMuted)
                    TextEditor(text: $model.draft).font(.body).frame(height: 100).disabled(model.running)
                        .padding(8).fwSection()
                    Button("Simulated Send") { model.simulatedSend() }.disabled(model.running || !model.canSend || model.draft.isEmpty)
                    Text("The first correction is scripted and labelled. No real messages are sent. Replay resets this isolated memory.")
                        .font(.caption2).foregroundStyle(FW.textMuted)
                }.padding(24).frame(width: 360)
            }
        }
        .background(FW.background)
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}
