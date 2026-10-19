import Foundation
import Flow

@main
struct VerifyLiveRewrite {
    @MainActor static func main() async throws {
        let pcm = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let engine = Flow(dbPath: ":memory:")
        let speech = CloudSpeechStream()
        let clock = ContinuousClock(), began = ContinuousClock.now
        var latest = "", recording = true, updates = 0
        var firstWordMs: Double?, output = "", frames = 0, requestCount = 0
        var wroteAfterStop = false
        speech.onText = { latest = $0; updates += 1 }
        speech.start()
        let rewriting = Task { @MainActor in
            var submitted = ""
            while recording && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard let candidate = LiveRewritePresentation.candidate(from: latest), candidate != submitted else { continue }
                submitted = candidate; requestCount += 1
                var text = ""
                do {
                    for try await event in DictationPresentation.smooth(engine.previewRewriteStream(text: candidate, appName: "Messages")) {
                        try Task.checkCancellation()
                        if !recording { wroteAfterStop = true; return }
                        if case .delta(let word) = event {
                            text += word
                            if LiveRewritePresentation.canDisplay(text, replacing: output) {
                                if firstWordMs == nil { firstWordMs = ms(began.duration(to: clock.now)) }
                                output = text; frames += 1
                            }
                        }
                    }
                } catch { if Task.isCancelled { return } }
            }
        }
        let values: [Float] = stride(from: 0, to: pcm.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8)) / 32767
        }
        for offset in stride(from: 0, to: values.count, by: 1600) {
            let end = min(values.count, offset + 1600)
            speech.append(samples: Array(values[offset..<end]), sampleRate: 16000)
            try await clock.sleep(until: began.advanced(by: .seconds(Double(end) / 16000)))
        }
        let stopMs = ms(began.duration(to: clock.now))
        recording = false; rewriting.cancel(); await rewriting.value
        let transcript = await speech.finish()
        let checks = ["llm_words_before_stop": firstWordMs.map { $0 < stopMs } ?? false,
            "multiple_live_llm_frames": frames > 1,
            "real_cloud_caption_updates": updates > 1,
            "command_not_in_provisional_message": !output.lowercased().contains("flow"),
            "no_stale_words_after_stop": !wroteAfterStop]
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
            "first_llm_word_after_speech_start_ms": firstWordMs ?? -1, "speech_stop_ms": stopMs,
            "live_output": output, "display_frames": frames, "preview_requests": requestCount,
            "cloud_updates": updates, "cloud_failure": speech.failureDescription ?? "", "asr_finalized": transcript != nil,
            "scope": "Generated PCM paced in real time through production Cloudflare speech client and speculative Rust rewriting with genuine LLM tokens. No microphone, Messages writes or production database. One sample, not a latency guarantee; macOS physical recording is not verified here."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "review/live-rewrite-verification.json"))
        print(String(decoding: data, as: UTF8.self))
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
