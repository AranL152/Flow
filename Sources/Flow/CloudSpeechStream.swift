import Foundation

public struct CloudSpeechServiceFailure: LocalizedError {
    public let code: String
    public var errorDescription: String? {
        switch code {
        case "quota_exhausted": return "Cloudflare's daily AI allowance is exhausted. Enable Workers Paid or wait for the daily reset."
        case "rate_limited": return "Cloudflare is temporarily rate limited. Please retry shortly."
        case "timeout": return "Cloudflare speech did not respond in time. Using recorded audio."
        default: return "Cloudflare speech is temporarily unavailable. Using recorded audio."
        }
    }
}

/// Revisions replace the current interim segment; finalized segments accumulate.
/// Only the server's closing Metadata can promote the result to final dictation.
struct CloudSpeechTranscript {
    private var segments: [(start: Double, duration: Double, text: String)] = []
    private var interim = ""
    private(set) var minimumConfidence: Double = 1
    private(set) var closed = false
    var text: String { (segments.map(\.text) + [interim]).filter { !$0.isEmpty }.joined(separator: " ") }
    var finalText: String? { closed && interim.isEmpty && !text.isEmpty && minimumConfidence >= 0.85 ? text : nil }

    mutating func receive(_ data: Data, closing: Bool) throws {
        guard data.count <= 131072,
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw CloudSpeechStream.failure("Invalid speech response") }
        if type == "Error" { throw CloudSpeechServiceFailure(code: event["code"] as? String ?? "unavailable") }
        if type == "Metadata" {
            if closing { closed = true }
            return
        }
        guard type == "Results" else { return }
        guard let channel = event["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let text = alternatives.first?["transcript"] as? String,
              let final = event["is_final"] as? Bool else { throw CloudSpeechStream.failure("Invalid transcript") }
        if final {
            guard let start = event["start"] as? Double, let duration = event["duration"] as? Double,
                  start.isFinite, duration.isFinite, start >= 0, duration >= 0 else { throw CloudSpeechStream.failure("Invalid speech timing") }
            interim = ""
            if !segments.contains(where: { $0.start == start && $0.duration == duration }), !text.isEmpty {
                let confidence = alternatives.first?["confidence"] as? Double ?? 0
                minimumConfidence = min(minimumConfidence, confidence.isFinite && (0...1).contains(confidence) ? confidence : 0)
                segments.append((start, duration, text)); segments.sort { $0.start < $1.start }
            }
        } else { interim = text }
        if self.text.count > 5000 { throw CloudSpeechStream.failure("Speech exceeds 5000 characters") }
    }
}

/// Streams the existing mono capture to Cloudflare. No new microphone or Speech
/// permission. Failure returns nil so the engine can transcribe its saved audio.
@MainActor
public final class CloudSpeechStream {
    public var onText: ((String) -> Void)?
    public var onFailure: (() -> Void)?
    public private(set) var sentFrames = 0
    public private(set) var responseCount = 0
    public private(set) var sentPackets = 0
    public private(set) var failureDescription: String?
    public private(set) var serviceFailure: CloudSpeechServiceFailure?
    public var minimumConfidence: Double { transcript.minimumConfidence }
    private let endpoint: URL
    private var socket: URLSessionWebSocketTask?
    private var outgoing: AsyncStream<Data>.Continuation?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var completion: CheckedContinuation<String?, Never>?
    private var transcript = CloudSpeechTranscript()
    private var packetizer: CloudSpeechAudioPackets?
    private var offset: UInt64 = 0
    private var rate: UInt32 = 0
    private var generation = UUID()
    private var active = false
    private var finishing = false
    private var closeSent = false
    private var terminal = false

    public init(endpoint: URL? = nil) {
        let configured = ProcessInfo.processInfo.environment["FLOW_SPEECH_ENDPOINT"].flatMap(URL.init(string:))
        self.endpoint = endpoint ?? configured ?? URL(string: "wss://base10-proxy.old-resonance-ed75.workers.dev/speech-stream")!
    }

    public func start() {
        cancel()
        transcript = CloudSpeechTranscript(); sentFrames = 0; responseCount = 0; sentPackets = 0
        failureDescription = nil; serviceFailure = nil
        active = true; finishing = false; closeSent = false; terminal = false
    }

    public func feed(from engine: Flow) {
        guard active, !finishing, !terminal else { return }
        for _ in 0..<8 {
            let chunk = engine.recordingSamples(after: offset)
            guard !chunk.frames.isEmpty else { break }
            append(samples: chunk.frames, sampleRate: chunk.sampleRate)
            offset = chunk.nextOffset
        }
    }

    public func append(samples: [Float], sampleRate: UInt32) {
        guard active, !finishing, !terminal, !samples.isEmpty else { return }
        guard (8000...48000).contains(sampleRate), rate == 0 || rate == sampleRate,
              sentFrames + samples.count <= Int(sampleRate) * 300 else {
            fail(Self.failure("Speech input rate changed or audio limit exceeded")); return
        }
        if socket == nil { connect(sampleRate: sampleRate) }
        let values: [Int16] = samples.map { value in
            let finite = value.isFinite ? value : 0
            return Int16((min(1, max(-1, finite)) * 32767).rounded()).littleEndian
        }
        let data = values.withUnsafeBytes { Data($0) }
        if packetizer == nil { packetizer = CloudSpeechAudioPackets(sampleRate: sampleRate) }
        sentFrames += samples.count
        for packet in packetizer!.append(data) {
            guard enqueue(packet) else { return }
        }
    }

    public func finish(from engine: Flow? = nil) async -> String? {
        if let engine { feed(from: engine) }
        guard active else { return nil }
        guard socket != nil, !terminal, !finishing else { return transcript.finalText }
        // A stalled stream must not add a second wait before batch fallback.
        // Brief recordings may legitimately get their first result after Stop.
        if sentFrames >= Int(rate) * 2 && transcript.text.isEmpty {
            fail(); return nil
        }
        if let tail = packetizer?.finish(), !enqueue(tail) { return nil }
        finishing = true; outgoing?.finish()
        let epoch = generation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.generation == epoch else { return }; self.fail()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if terminal { continuation.resume(returning: transcript.finalText) }
                else { completion = continuation }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    public func cancel() {
        generation = UUID(); active = false; terminal = true
        outgoing?.finish(); outgoing = nil
        sender?.cancel(); receiver?.cancel(); timeout?.cancel()
        sender = nil; receiver = nil; timeout = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        completion?.resume(returning: nil); completion = nil
        offset = 0; rate = 0; packetizer = nil
    }

    private func enqueue(_ data: Data) -> Bool {
        guard case .enqueued = outgoing?.yield(data) else {
            fail(Self.failure("Real-time audio send queue filled; using recorded audio.")); return false
        }
        sentPackets += 1
        return true
    }

    private func connect(sampleRate: UInt32) {
        rate = sampleRate
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "sample_rate", value: String(sampleRate))]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.maximumMessageSize = 131072
        self.socket = socket
        let queue = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        outgoing = queue.continuation
        let epoch = generation
        socket.resume()
        sender = Task { [weak self] in
            do {
                for await data in queue.stream {
                    try Task.checkCancellation()
                    try await socket.send(.data(data))
                }
                guard let self, self.generation == epoch, !Task.isCancelled else { return }
                self.closeSent = true
                try await socket.send(.string("{\"type\":\"CloseStream\"}"))
            } catch {
                // An upgraded service may send an actionable Error frame then
                // close. Let the receiver consume it before a failed audio send
                // replaces that reason with a generic transport error.
                if self?.responseCount == 0 { try? await Task.sleep(for: .milliseconds(150)) }
                guard let self, self.generation == epoch else { return }; self.fail(error)
            }
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == epoch, !self.terminal else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: throw Self.failure("Unsupported speech response")
                    }
                    let previous = self.transcript.text
                    try self.transcript.receive(data, closing: self.closeSent)
                    self.responseCount += 1
                    if !self.transcript.text.isEmpty, self.transcript.text != previous { self.onText?(self.transcript.text) }
                    if self.transcript.closed {
                        guard let final = self.transcript.finalText else { self.fail(); return }
                        self.terminal = true; self.timeout?.cancel()
                        self.completion?.resume(returning: final); self.completion = nil
                        socket.cancel(with: .normalClosure, reason: nil)
                        return
                    }
                }
            } catch {
                guard let self, self.generation == epoch else { return }; self.fail(error)
            }
        }
    }

    private func fail(_ error: Error? = nil) {
        guard !terminal else { return }
        failureDescription = error?.localizedDescription ?? "Cloud speech did not finish; using recorded audio."
        serviceFailure = error as? CloudSpeechServiceFailure
        cancel(); onFailure?()
    }

    nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "Flow.CloudSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
