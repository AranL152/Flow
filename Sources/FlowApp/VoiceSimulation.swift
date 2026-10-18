import AppKit
import AVFoundation
import Flow
import SwiftUI

struct SimulationSavedEdit: Identifiable {
    let id = UUID()
    let before: String
    let after: String
    let scripted: Bool
    var edited: Bool { before.split(whereSeparator: \.isWhitespace) != after.split(whereSeparator: \.isWhitespace) }
}

/// Audible fixtures run through Apple's live recognizer and the normal Rust
/// audio → Whisper → streamed formatting → final-text learning pipeline.
@MainActor
final class VoiceSimulationModel: ObservableObject {
    @Published var running = false
    @Published var stage = "Ready to simulate voice input"
    @Published var draft = ""
    @Published var sent = ""
    @Published var error: String?
    @Published var finished = false
    @Published var readableStreaming = true
    @Published var draftPhase = "Waiting for voice"
    @Published var canSend = false
    @Published var chunkCount = 0
    @Published var savedEdits: [SimulationSavedEdit] = []
    @Published var requestedAfterLatestEdit = false
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
                sent = ""; canSend = false; savedEdits = []; requestedAfterLatestEdit = false; events = []; started = Date()
                state.currentApp = "Messages"; state.targetAppName = "Messages · Alex (simulation)"
                state.lastTranscription = nil; state.liveTranscript = ""; state.streamedOutput = ""
                stage = "1 / 3 · Generated voice → real captions and model output"
                try await take(name: "first")
                try await Task.sleep(for: .seconds(1.5))
                stage = "2 / 3 · Simulated user edit: “slides” → “deck”, then Send"
                let original = draft
                let correction = "yo can u check the deck tomorrow?"
                // This is an explicitly labelled scripted edit, never fabricated
                // model output. Sending here updates only the in-memory fixture.
                draft = correction
                note("simulated_edit", text: correction)
                try await Task.sleep(for: .seconds(1.5))
                guard state.engine.recordFinalTextForContact(correction, contactName: "Alex") >= 0 else { throw failure("The contact-specific edit could not be saved") }
                canSend = false
                guard state.engine.styleStats?.edited == 1 else { throw failure("The edited example was not saved") }
                savedEdits.append(SimulationSavedEdit(before: original, after: correction, scripted: true))
                sent = correction; draft = ""
                requestedAfterLatestEdit = false
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

    func dictateAgain() {
        guard !running else { return }
        running = true; error = nil; finished = false
        task = Task {
            do {
                state.engine.discardPendingDictation()
                stage = "Dictating again with your saved edits for Alex"
                try await take(name: "second")
                finished = true
                stage = "Ready · edit and send to refine Alex’s next response"
                saveReport(status: "passed")
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; saveReport(status: "failed") }
            }
            captions.cancel(); player?.stop(); indicator?.hide()
            state.isRecording = false; state.isProcessing = false; state.isStreamingOutput = false
            running = false
        }
    }

    func simulatedSend() {
        guard !running, canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard state.engine.recordFinalTextForContact(draft, contactName: "Alex") >= 0 else {
            error = "This draft no longer has a completed baseline for Alex. Dictate again."
            return
        }
        let edit = SimulationSavedEdit(before: state.lastTranscription ?? "", after: draft, scripted: false)
        savedEdits.append(edit)
        note("manual_send_saved", text: draft)
        canSend = false
        sent = draft; draft = ""
        requestedAfterLatestEdit = false
        stage = "Saved for Alex. Click Dictate again to use your edit in the next response."
        saveReport(status: "passed")
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
        draft = ""; draftPhase = "Listening · waiting for LLM output"; canSend = false; chunkCount = 0; state.liveTranscript = ""; state.streamedOutput = ""; state.isStreamingOutput = false
        state.isRecording = true; state.isProcessing = false; state.recordingDuration = 0
        captions.onText = { [weak self] text, final in
            self?.state.liveTranscript = text
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
        draftPhase = "Waiting for LLM output"
        note("composer_before_model", text: draft)
        requestedAfterLatestEdit = !savedEdits.isEmpty
        note("saved_examples_available", text: String(savedEdits.count))
        var gotCompletion = false
        // Receive independently from presentation, so recorded receipt times
        // retain actual model latency when readable playback is enabled.
        let queue = AsyncThrowingStream<DictationStreamEvent, Error>.makeStream()
        let producer = Task {
            do {
                for try await event in state.engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: "Alex") {
                    try Task.checkCancellation()
                    switch event {
                    case .attachment(let plan): note("attachment_request", text: plan.command)
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
            case .attachment(let plan): state.attachments.receive(plan)
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
            "saved_edits": savedEdits.map { ["before": $0.before, "after": $0.after, "contact": "Alex", "scripted": $0.scripted] as [String: Any] },
            "saved_examples_available": savedEdits.count,
            "requested_after_latest_edit": requestedAfterLatestEdit,
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
                Button(model.running ? "Running…" : "Reset and replay") { model.start() }.disabled(model.running)
            }.padding(18).background(FW.surface)
            Divider()
            HStack(spacing: 0) {
                RecordView().environmentObject(model.state).frame(minWidth: 560)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Label("Alex", systemImage: "person.crop.circle.fill").font(.title2.weight(.semibold))
                    Text("Simulated conversation · Project review").font(.caption).foregroundStyle(FW.textMuted)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(model.stage).font(.subheadline.weight(.medium))
                            if !model.sent.isEmpty {
                                Text(model.sent).padding(14).frame(maxWidth: .infinity, alignment: .trailing)
                                    .background(FW.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                                Text("Sent to this simulated conversation").font(.caption).foregroundStyle(FW.textMuted)
                            }
                            if let latest = model.savedEdits.last {
                                savedEditCard(latest)
                                if model.savedEdits.count > 1 {
                                    DisclosureGroup("All saved examples (\(model.savedEdits.count))") {
                                        ForEach(model.savedEdits.dropLast().reversed()) { edit in
                                            savedEditCard(edit).padding(.top, 8)
                                        }
                                    }.font(.caption)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
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
                    if !model.running && model.canSend && model.draft != model.state.lastTranscription {
                        Text("Your edit will be remembered for Alex when you send.")
                            .font(.caption).foregroundStyle(FW.accent)
                    }
                    HStack {
                        Button("Simulated Send") { model.simulatedSend() }.disabled(model.running || !model.canSend || model.draft.isEmpty)
                        Button("Dictate again") { model.dictateAgain() }.disabled(model.running)
                    }
                    Text("The first correction is scripted and labelled. No real messages are sent. Replay resets this isolated memory.")
                        .font(.caption2).foregroundStyle(FW.textMuted)
                }.padding(24).frame(width: 360)
            }
        }
        .background(FW.background)
        .task { model.start() }
        .onDisappear { model.stop() }
    }
    private func savedEditCard(_ edit: SimulationSavedEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(edit.edited ? "Edit saved for Alex" : "Example saved for Alex", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(FW.accent)
            Text("Flow generated").font(.caption2).foregroundStyle(FW.textMuted)
            Text(edit.before).font(.caption).foregroundStyle(FW.textSecondary).textSelection(.enabled)
            Text("You sent").font(.caption2).foregroundStyle(FW.textMuted)
            Text(edit.after).font(.callout.weight(.medium)).foregroundStyle(FW.textPrimary).textSelection(.enabled)
            Text(model.requestedAfterLatestEdit
                 ? "New response requested with Alex’s saved examples. Wording may vary."
                 : "Saved. Click Dictate again to use your saved examples in the next response.")
                .font(.caption2).foregroundStyle(FW.textMuted)
            Text(edit.scripted ? "Scripted example · isolated user + Alex" : "Your edit · isolated user + Alex")
                .font(.caption2).foregroundStyle(FW.textMuted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).fwSection()
    }

}
