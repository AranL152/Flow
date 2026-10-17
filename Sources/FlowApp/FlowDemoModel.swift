import Foundation
import SwiftUI
import Flow

struct DemoMemoryNote: Decodable, Identifiable {
    let id: String
    let before: String
    let after: String
    let context: String
    var edited: Bool { before.trimmingCharacters(in: .whitespacesAndNewlines) != after.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct DemoRecipient: Decodable, Identifiable {
    let id: String
    let name: String
    let role: String
    var history: [String]
    var memory: [DemoMemoryNote]
    var draft = ""
    var status = "idle"
    var ticket: String?
    var evidenceCount = 0
    var preservedOriginal = false
    enum CodingKeys: String, CodingKey { case id, name, role, history, memory }
}

@MainActor
final class FlowDemoModel: ObservableObject {
    @Published var recipients: [DemoRecipient] = []
    @Published var transcript = "" { didSet { if transcript != oldValue { invalidate() } } }
    @Published var context = "Project review" { didSet { if context != oldValue { invalidate() } } }
    @Published var isRecording = false
    @Published var isGenerating = false
    @Published var audioLevel: Float = 0
    @Published var error: String?
    @Published var activity = "Speak once. See how your words change for each person."
    private var engine: Flow?
    private let speech = DemoSpeechCapture()
    private var generation = UUID()
    private var speechSession = UUID()
    private var requests: [String: Task<Void, Never>] = [:]
    private var previewTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var isLoaded = false

    func load() async {
        guard !isLoaded else { return }
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("flow")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            engine = Flow(dbPath: folder.appendingPathComponent("demo-conversations.db").path)
            try refresh()
            isLoaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func call(_ request: [String: Any]) throws -> Data {
        guard let engine else { throw failure("Demo is still loading") }
        return try engine.demoRequest(request)
    }

    private func refresh() throws {
        struct Snapshot: Decodable { let recipients: [DemoRecipient] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: call(["op": "load"]))
        recipients = snapshot.recipients.map { fresh in
            var value = fresh
            if let old = recipients.first(where: { $0.id == fresh.id }) {
                value.draft = old.draft; value.status = old.status; value.ticket = old.ticket; value.evidenceCount = old.evidenceCount; value.preservedOriginal = old.preservedOriginal
            }
            return value
        }
    }

    func setDraft(id: String, text: String) {
        guard let i = recipients.firstIndex(where: { $0.id == id }), recipients[i].status == "ready" else { return }
        recipients[i].draft = text
    }

    private func invalidate() {
        generation = UUID()
        requests.values.forEach { $0.cancel() }; requests.removeAll()
        previewTask?.cancel()
        isGenerating = false
        for i in recipients.indices {
            if recipients[i].status != "sent" { recipients[i].status = "idle" }
            recipients[i].ticket = nil
        }
        if engine != nil { _ = try? call(["op": "cancel"]) }
    }

    func startRecording() {
        guard !isRecording else { return }
        invalidate(); stopTask?.cancel(); speech.cancel()
        error = nil; transcript = ""; isRecording = true
        activity = "Listening on your Mac…"
        let session = UUID(); speechSession = session
        startTask = Task {
            do {
                try await speech.start(onText: { [weak self] text, final in
                    guard let self, self.speechSession == session else { return }
                    self.transcript = text
                    if final {
                        self.stopTask?.cancel(); self.isRecording = false; self.audioLevel = 0
                        self.generate()
                    } else if self.isRecording {
                        self.previewTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            guard !Task.isCancelled, let self, self.isRecording else { return }
                            self.beginGeneration(provisional: true)
                        }
                    }
                }, onLevel: { [weak self] level in
                    guard self?.speechSession == session else { return }; self?.audioLevel = level
                }, onError: { [weak self] message in
                    guard let self, self.speechSession == session else { return }
                    self.isRecording = false; self.audioLevel = 0; self.invalidate()
                    self.error = message; self.activity = "You can still type a message and generate drafts."
                })
                if self.speechSession != session { self.speech.cancel() }
            } catch {
                guard self.speechSession == session else { return }
                self.isRecording = false; self.audioLevel = 0; self.error = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false; audioLevel = 0; previewTask?.cancel(); speech.stop()
        activity = "Finishing your words…"
        let session = speechSession
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled, let self, self.speechSession == session else { return }
            self.speech.cancel(); self.speechSession = UUID(); self.generate()
        }
    }

    func generate() {
        guard !isRecording else { return }
        previewTask?.cancel()
        beginGeneration(provisional: false)
    }

    private func beginGeneration(provisional: Bool) {
        let input = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !scope.isEmpty else {
            if !provisional { error = "Add a message and a conversation context first." }; return
        }
        invalidate(); error = nil
        let current = generation
        activity = provisional ? "Live preview · drafts can change while you speak" : "Matching your words to each conversation…"
        isGenerating = true
        for index in recipients.indices {
            let id = recipients[index].id
            recipients[index].status = "generating"; recipients[index].draft = ""; recipients[index].preservedOriginal = false
            requests[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let prepared = try self.call(["op": "prepare", "recipient_id": id, "said": input, "context": scope])
                    guard let object = try JSONSerialization.jsonObject(with: prepared) as? [String: Any],
                          let ticket = object["ticket"] as? String, let body = object["request"] else { throw self.failure("Invalid formatting request") }
                    let endpoint = ProcessInfo.processInfo.environment["FLOW_DEMO_ENDPOINT"]
                        ?? Bundle.main.object(forInfoDictionaryKey: "FlowDemoEndpoint") as? String
                        ?? "https://base10-proxy.old-resonance-ed75.workers.dev/format-stream"
                    guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme ?? "") else { throw self.failure("Invalid streaming endpoint") }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"; request.timeoutInterval = 45
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          response.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
                        throw self.failure("Streaming endpoint unavailable. Start the demo worker or deploy /format-stream.")
                    }
                    var decoder = DemoStreamDecoder()
                    // AsyncBytes.lines can omit blank lines on some OS versions;
                    // preserve SSE frame boundaries explicitly instead.
                    var lineBytes: [UInt8] = []
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard self.generation == current else { return }
                        if byte != 10 {
                            lineBytes.append(byte)
                            guard lineBytes.count <= 50000 else { throw self.failure("Stream line is too long") }
                            continue
                        }
                        if lineBytes.last == 13 { lineBytes.removeLast() }
                        guard let line = String(bytes: lineBytes, encoding: .utf8) else { throw self.failure("Invalid stream encoding") }
                        lineBytes.removeAll(keepingCapacity: true)
                        if let event = try decoder.accept(line: line) {
                            guard let i = self.recipients.firstIndex(where: { $0.id == id }) else { return }
                            switch event {
                            case .delta: self.recipients[i].draft = decoder.text
                            case .done(let text):
                                self.recipients[i].draft = text
                                if provisional { self.recipients[i].status = "listening" }
                                else {
                                    let completed = try self.call(["op": "complete", "ticket": ticket, "output": text])
                                    if let receipt = try JSONSerialization.jsonObject(with: completed) as? [String: Any] {
                                        self.recipients[i].draft = receipt["output"] as? String ?? text
                                        self.recipients[i].preservedOriginal = receipt["preserved_original"] as? Bool ?? false
                                    }
                                    self.recipients[i].ticket = ticket; self.recipients[i].status = "ready"
                                    self.recipients[i].evidenceCount = (object["evidence_ids"] as? [String])?.count ?? 0
                                }
                            }
                        }
                        if decoder.completed { break }
                    }
                    try decoder.finish()
                } catch {
                    guard self.generation == current, !Task.isCancelled else { return }
                    if let i = self.recipients.firstIndex(where: { $0.id == id }) {
                        self.recipients[i].status = "error"; self.recipients[i].ticket = nil
                    }
                    self.error = error.localizedDescription
                }
                guard self.generation == current else { return }
                self.requests[id] = nil
                self.isGenerating = !self.requests.isEmpty
                if !self.isGenerating && !provisional {
                    self.activity = self.error == nil ? "Edit a draft, then Send to teach Flow in this context." : "A draft failed. Retry before sending."
                }
            }
        }
    }

    func send(id: String) {
        guard !isRecording, let i = recipients.firstIndex(where: { $0.id == id }),
              recipients[i].status == "ready", let ticket = recipients[i].ticket else { return }
        do {
            let data = try call(["op": "send", "ticket": ticket, "text": recipients[i].draft])
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            recipients[i].status = "sent"; recipients[i].ticket = nil
            activity = result?["edited"] as? Bool == true
                ? "Edit remembered for \(recipients[i].name) · \(context). An example, not a permanent rule."
                : "Saved to \(recipients[i].name)’s demo conversation."
            try refresh()
        } catch { self.error = error.localizedDescription }
    }

    func forget(recipientID: String, noteID: String) {
        do {
            invalidate()
            _ = try call(["op": "forget", "recipient_id": recipientID, "note_id": noteID])
            try refresh(); activity = "Example forgotten. Future drafts won’t use it."
        } catch { self.error = error.localizedDescription }
    }

    func reset() {
        shutdown()
        do {
            _ = try call(["op": "reset"]); recipients = []; try refresh()
            transcript = ""; error = nil; activity = "Synthetic histories restored. Nothing from your real messages was imported."
        } catch { self.error = error.localizedDescription }
    }

    func shutdown() {
        speechSession = UUID(); startTask?.cancel(); stopTask?.cancel(); speech.cancel()
        isRecording = false; audioLevel = 0; invalidate()
    }

    private func failure(_ text: String) -> NSError { NSError(domain: "Flow.Demo", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
