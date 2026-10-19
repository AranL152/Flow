import Foundation
import Flow
import Darwin

@main
struct VerifyCloudSpeech {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let pcm = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let report = URL(fileURLWithPath: args[2])
        let expectedWord = args.count > 3 ? args[3] : "issue"
        let speech = CloudSpeechStream()
        let clock = ContinuousClock()
        let began = clock.now
        var updates = 0, revisions: [String] = []
        var updateTimes: [Double] = []
        speech.onText = { text in updates += 1; revisions.append(text); updateTimes.append(milliseconds(began.duration(to: clock.now))) }
        speech.start()
        let values: [Float] = stride(from: 0, to: pcm.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8)) / 32767
        }
        for offset in stride(from: 0, to: values.count, by: 1600) {
            let end = min(values.count, offset + 1600)
            speech.append(samples: Array(values[offset..<end]), sampleRate: 16000)
            try await clock.sleep(until: began.advanced(by: .seconds(Double(end) / 16000)))
        }
        let stop = clock.now
        let liveUpdates = updates
        let transcript = await speech.finish()
        let finalize = milliseconds(stop.duration(to: clock.now))
        var results: [[String: Any]] = []
        for realtime in [true, false] {
            let engine = Flow(dbPath: ":memory:")
            let requestStart = clock.now
            var first: Double?, output = "", final = "", chunks = 0, plan: AttachmentPlan?
            var failure = ""
            do {
                for try await event in engine.transcribeAudioStream(pcm16: pcm, sampleRate: 16000, appName: "Messages", contactName: "Alex", finalTranscript: realtime ? transcript : nil) {
                    switch event {
                    case .delta(let delta):
                        if first == nil { first = milliseconds(requestStart.duration(to: clock.now)) }
                        chunks += 1; output += delta
                    case .attachment(let value): plan = value
                    case .completed(let value): final = value
                    }
                }
            } catch { failure = error.localizedDescription }
            let valid = final == output.trimmingCharacters(in: .whitespacesAndNewlines) && final.lowercased().contains(expectedWord) &&
                plan?.request?.source == .fileSearch && !final.lowercased().contains("flow find")
            results.append(["route": realtime ? "realtime" : "batch", "valid": valid,
                "request_to_first_llm_delta_ms": first ?? -1,
                "stop_to_first_llm_delta_ms": (first ?? -1) + (realtime ? finalize : 0),
                "request_to_complete_ms": milliseconds(requestStart.duration(to: clock.now)),
                "real_model_chunks": chunks, "output": final, "error": failure, "used_realtime_transcript": realtime && transcript != nil])
        }
        let success = results.allSatisfy { $0["valid"] as? Bool == true } && (transcript == nil || liveUpdates > 0)
        let result: [String: Any] = ["status": success ? "passed" : "failed", "final_cloud_transcript": transcript ?? "",
            "live_updates_before_stop": liveUpdates, "finalization_ms": finalize,
            "first_live_caption_ms": updateTimes.first ?? -1, "caption_update_times_ms": updateTimes,
            "cloud_failure": speech.failureDescription ?? "", "minimum_confidence": speech.minimumConfidence,
            "revisions": revisions,
            "audio_seconds": Double(values.count) / 16000, "cases": results,
            "scope": "One generated-speech fixture, paced in real time. Production Swift WebSocket client, deployed Cloudflare Nova, Rust personalization/attachment pipeline and real streamed LLM responses. No microphone, Messages writes or production database. Timings are a single sequential sample, not median/p95 or a latency guarantee."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print(String(data: try Data(contentsOf: report), encoding: .utf8)!)
        if !success { exit(1) }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
