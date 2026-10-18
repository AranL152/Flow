//
// Flow.swift
// Flow Swift Wrapper
//
// A Swift-friendly interface to the Flow Rust core.
//

import CFlow
import Foundation
import AppKit

/// Writing modes for text style adjustment
public enum WritingMode: UInt8, Sendable, CaseIterable {
    case formal = 0
    case casual = 1
    case veryCasual = 2
    case excited = 3

    public var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very Casual"
        case .excited: return "Excited"
        }
    }

    public var description: String {
        switch self {
        case .formal: return "Professional with full punctuation"
        case .casual: return "Conversational but clear"
        case .veryCasual: return "Lowercase, minimal punctuation"
        case .excited: return "Energetic with exclamation!"
        }
    }
}

/// App categories for mode suggestions
public enum AppCategory: UInt8, Sendable {
    case email = 0
    case slack = 1
    case code = 2
    case documents = 3
    case social = 4
    case browser = 5
    case terminal = 6
    case unknown = 7

    public var displayName: String {
        switch self {
        case .email: return "Email"
        case .slack: return "Chat"
        case .code: return "Code"
        case .documents: return "Documents"
        case .social: return "Social"
        case .browser: return "Browser"
        case .terminal: return "Terminal"
        case .unknown: return "Other"
        }
    }
}

/// Completion provider options
public enum CompletionProvider: UInt8, Sendable {
    case openAI = 0
    case gemini = 1
    case openRouter = 2

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        }
    }
}

/// Cloud transcription provider options (for remote transcription)
public enum CloudTranscriptionProvider: UInt8, Sendable, CaseIterable {
    case openAI = 0
    case auto = 1

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .auto: return "Auto"
        }
    }

    public var description: String {
        switch self {
        case .openAI: return "OpenAI Whisper API"
        case .auto: return "Fastest available (recommended)"
        }
    }
}

/// Whisper model sizes for local transcription
public enum WhisperModel: UInt8, Sendable {
    case turbo = 0 // Quantized tiny (~15MB) - blazing fast
    case fast = 1 // Tiny (~39MB)
    case balanced = 2 // Base (~142MB)
    case quality = 3 // Distil-medium (~400MB) - recommended
    case best = 4 // Distil-large-v3 (~750MB)

    public var displayName: String {
        switch self {
        case .turbo: return "Turbo"
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        case .best: return "Best"
        }
    }

    public var sizeDescription: String {
        switch self {
        case .turbo: return "~15MB, quantized, blazing fast"
        case .fast: return "~39MB, good speed"
        case .balanced: return "~142MB, balanced"
        case .quality: return "~400MB, recommended"
        case .best: return "~750MB, highest accuracy"
        }
    }
}

/// Transcription mode: local or remote
public enum TranscriptionMode: Sendable {
    case local(model: WhisperModel)
    case remote

    public var displayName: String {
        switch self {
        case let .local(model): return "Local (\(model.displayName))"
        case .remote: return "Cloud API"
        }
    }
}

/// A learned correction from user edits
public struct Correction: Identifiable, Sendable {
    public let id: String
    public let original: String
    public let corrected: String
    public let occurrences: Int
    public let confidence: Double
    public let source: String
    public let createdAt: Date
    public let updatedAt: Date
}

/// Validation result for a correction pair
public struct CorrectionValidation: Sendable {
    public let original: String
    public let corrected: String
    public let valid: Bool
    public let reason: String?
}

/// Main interface to the Flow engine
public final class Flow: @unchecked Sendable {
    /// Mono Float32 frames from the existing Rust microphone capture.
    public struct RecordingSamples {
        public let frames: [Float]
        public let sampleRate: UInt32
        public let nextOffset: UInt64
    }

    public func recordingSamples(after offset: UInt64, capacity: Int = 8192) -> RecordingSamples {
        guard let handle else { return RecordingSamples(frames: [], sampleRate: 0, nextOffset: offset) }
        var frames = [Float](repeating: 0, count: min(65536, max(1, capacity)))
        var sampleRate: UInt32 = 0
        let count = frames.withUnsafeMutableBufferPointer {
            flow_read_recording_samples(handle, offset, $0.baseAddress, $0.count, &sampleRate)
        }
        return RecordingSamples(frames: Array(frames.prefix(count)), sampleRate: sampleRate, nextOffset: offset + UInt64(count))
    }
    private let handle: OpaquePointer?

    /// Demo-only persistent conversations. Serialize calls on the main actor.
    public func demoRequest(_ request: [String: Any]) throws -> Data {
        guard let handle else { throw NSError(domain: "Flow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Flow could not open its database"]) }
        let encoded = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: encoded, as: UTF8.self)
        guard let output = json.withCString({ takeString(flow_demo_dispatch(handle, $0)) }),
              let data = output.data(using: .utf8) else {
            throw NSError(domain: "Flow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Flow returned no demo response"])
        }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? String {
            throw NSError(domain: "Flow", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
        }
        return data
    }

    /// Initialize the Flow engine
    /// - Parameter dbPath: Optional path to the SQLite database. If nil, uses default location.
    public init(dbPath: String? = nil) {
        let path = dbPath ?? {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let flowDir = appSupport.appendingPathComponent("flow")

            // Create directory if needed
            try? fm.createDirectory(at: flowDir, withIntermediateDirectories: true)

            return flowDir.appendingPathComponent("flow.db").path
        }()

        handle = path.withCString { cPath in
            flow_init(cPath)
        }
    }

    deinit {
        if let handle = handle {
            flow_destroy(handle)
        }
    }

    /// Check if the engine is properly initialized
    public var isInitialized: Bool {
        handle != nil
    }

    // MARK: - Configuration

    /// Check if the transcription provider is configured
    public var isConfigured: Bool {
        guard let handle = handle else { return false }
        return flow_is_configured(handle)
    }

    // MARK: - Audio

    /// Start audio recording
    /// - Returns: true if recording started successfully
    public func startRecording() -> Bool {
        guard let handle = handle else { return false }
        let contact = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.MobileSMS"
            ? MessagesContext.currentContact() : nil
        return withOptionalCString(contact) { flow_start_recording_with_contact(handle, $0) }
    }

    /// Stop audio recording
    /// - Returns: Duration of the recording in milliseconds, or 0 on failure
    public func stopRecording() -> UInt64 {
        guard let handle = handle else { return 0 }
        return flow_stop_recording(handle)
    }

    /// Check if currently recording
    public var isRecording: Bool {
        guard let handle = handle else { return false }
        return flow_is_recording(handle)
    }

    /// Get current audio level (RMS amplitude) from the recording
    /// - Returns: A value between 0.0 and 1.0, or 0.0 if not recording
    public var audioLevel: Float {
        guard let handle = handle else { return 0.0 }
        return flow_get_audio_level(handle)
    }

    // MARK: - Transcription

    /// Validated inert request from the latest completed dictation, never a path.
    public var pendingAttachmentPlan: AttachmentPlan? {
        guard let handle, let json = takeString(flow_get_attachment_plan(handle)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttachmentPlan.self, from: data)
    }

    /// Ordered real provider deltas, followed by one validated completed result.
    /// Providers without streaming support emit only the completed result.
    public func transcribeStream(appName: String? = nil, finalTranscript: String? = nil) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        dictationStream(appName: appName, finalTranscript: finalTranscript)
    }

    /// Imported/simulated mono signed little-endian PCM16. Uses the same Rust
    /// provider, streaming callback, history and send-learning path as recording.
    /// Serialize transcription calls on one engine.
    public func transcribeAudioStream(pcm16: Data, sampleRate: UInt32, appName: String?, contactName: String? = nil, finalTranscript: String? = nil) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        dictationStream(appName: appName, pcm16: pcm16, sampleRate: sampleRate, contactName: contactName, finalTranscript: finalTranscript)
    }

    private func dictationStream(appName: String?, pcm16: Data? = nil, sampleRate: UInt32 = 0, contactName: String? = nil, finalTranscript: String? = nil) -> AsyncThrowingStream<DictationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let receiver = DictationStreamReceiver(continuation: continuation)
            continuation.onTermination = { [weak receiver] _ in receiver?.cancel() }
            Task.detached { [self] in
                guard let handle = self.handle else {
                    continuation.finish(throwing: NSError(domain: "Flow.Stream", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Flow could not initialize"]))
                    return
                }
                let context = Unmanaged.passRetained(receiver).toOpaque()
                defer { Unmanaged<DictationStreamReceiver>.fromOpaque(context).release() }
                let result = self.withOptionalCString(appName) { app in
                    if let pcm16 {
                        return self.withOptionalCString(contactName) { contact in
                            pcm16.withUnsafeBytes { bytes in
                                self.withOptionalCString(finalTranscript) { transcript in
                                    flow_transcribe_audio_realtime_stream(handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                                        pcm16.count, sampleRate, app, contact, transcript, nativeDictationDelta, context)
                                }
                            }
                        }
                    }
                    return self.withOptionalCString(finalTranscript) { transcript in
                        flow_transcribe_realtime_stream(handle, app, transcript, nativeDictationDelta, context)
                    }
                }
                defer { if let result { flow_free_string(result) } }
                if receiver.isCancelled { continuation.finish(throwing: CancellationError()); return }
                guard let result else {
                    continuation.finish(throwing: NSError(domain: "Flow.Stream", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: self.lastError ?? "Dictation streaming failed"]))
                    return
                }
                if let plan = self.pendingAttachmentPlan { continuation.yield(.attachment(plan)) }
                continuation.yield(.completed(String(cString: result)))
                continuation.finish()
            }
        }
    }

    /// Transcribe the recorded audio and process it
    /// - Parameter appName: Optional name of the current app for mode selection
    /// - Returns: Processed text, or nil on failure
    public func transcribe(appName: String? = nil) -> String? {
        guard let handle = handle else { return nil }

        let startTime = Date()
        print("[\(ISO8601DateFormatter().string(from: startTime))] 🦀 [RUST/FFI] Entering Rust transcription")

        let result: UnsafeMutablePointer<CChar>?
        if let app = appName {
            result = app.withCString { cApp in
                flow_transcribe(handle, cApp)
            }
        } else {
            result = flow_transcribe(handle, nil)
        }

        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        print("[\(ISO8601DateFormatter().string(from: endTime))] 🦀 [RUST/FFI] Exited Rust transcription - Duration: \(String(format: "%.2f", duration))s")

        guard let cString = result else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    /// Retry the last transcription using cached audio
    /// - Parameter appName: Optional name of the current app for mode selection
    /// - Returns: Processed text, or nil on failure
    public func retryLastTranscription(appName: String? = nil) -> String? {
        guard let handle = handle else { return nil }

        let result: UnsafeMutablePointer<CChar>?
        if let app = appName {
            result = app.withCString { cApp in
                flow_retry_last_transcription(handle, cApp)
            }
        } else {
            result = flow_retry_last_transcription(handle, nil)
        }

        guard let cString = result else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    // MARK: - Shortcuts

    /// Add a voice shortcut
    /// - Parameters:
    ///   - trigger: The trigger phrase
    ///   - replacement: The replacement text
    /// - Returns: true on success
    public func addShortcut(trigger: String, replacement: String) -> Bool {
        guard let handle = handle else { return false }
        return trigger.withCString { cTrigger in
            replacement.withCString { cReplacement in
                flow_add_shortcut(handle, cTrigger, cReplacement)
            }
        }
    }

    /// Remove a voice shortcut
    /// - Parameter trigger: The trigger phrase to remove
    /// - Returns: true on success
    public func removeShortcut(trigger: String) -> Bool {
        guard let handle = handle else { return false }
        return trigger.withCString { cTrigger in
            flow_remove_shortcut(handle, cTrigger)
        }
    }

    /// Get the number of shortcuts
    public var shortcutCount: Int {
        guard let handle = handle else { return 0 }
        return flow_shortcut_count(handle)
    }

    // MARK: - Writing Modes

    /// Set the writing mode for an app
    /// - Parameters:
    ///   - mode: The writing mode to set
    ///   - appName: The name of the app
    /// - Returns: true on success
    public func setMode(_ mode: WritingMode, for appName: String) -> Bool {
        guard let handle = handle else { return false }
        return appName.withCString { cApp in
            flow_set_app_mode(handle, cApp, mode.rawValue)
        }
    }

    /// Get the writing mode for an app
    /// - Parameter appName: The name of the app
    /// - Returns: The writing mode for the app
    public func getMode(for appName: String) -> WritingMode {
        guard let handle = handle else { return .casual }
        let rawValue = appName.withCString { cApp in
            flow_get_app_mode(handle, cApp)
        }
        return WritingMode(rawValue: rawValue) ?? .casual
    }

    // MARK: - Learning

    /// Report a user edit to learn from
    /// - Parameters:
    ///   - original: The original transcribed text
    ///   - edited: The text after user edits
    /// - Returns: true on success
    public func learnFromEdit(original: String, edited: String) -> Bool {
        guard let handle = handle else { return false }
        return original.withCString { cOriginal in
            edited.withCString { cEdited in
                flow_learn_from_edit(handle, cOriginal, cEdited)
            }
        }
    }

    /// Get the number of learned corrections
    public var correctionCount: Int {
        guard let handle = handle else { return 0 }
        return flow_correction_count(handle)
    }

    /// Get all learned corrections
    public var corrections: [Correction] {
        guard let handle = handle else { return [] }
        guard let cString = flow_get_corrections_json(handle) else { return [] }
        let jsonString = String(cString: cString)
        flow_free_string(cString)

        guard let data = jsonString.data(using: .utf8) else { return [] }

        struct RawCorrection: Decodable {
            let id: String
            let original: String
            let corrected: String
            let occurrences: Int
            let confidence: Double
            let source: String
            let created_at: String
            let updated_at: String
        }

        let decoder = JSONDecoder()
        guard let rawCorrections = try? decoder.decode([RawCorrection].self, from: data) else {
            return []
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        return rawCorrections.map { raw in
            let createdAt = dateFormatter.date(from: raw.created_at)
                ?? standardFormatter.date(from: raw.created_at)
                ?? Date()
            let updatedAt = dateFormatter.date(from: raw.updated_at)
                ?? standardFormatter.date(from: raw.updated_at)
                ?? Date()

            return Correction(
                id: raw.id,
                original: raw.original,
                corrected: raw.corrected,
                occurrences: raw.occurrences,
                confidence: raw.confidence,
                source: raw.source,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    /// Delete a correction by ID
    /// - Parameter id: The UUID string of the correction to delete
    /// - Returns: true if the correction was deleted
    public func deleteCorrection(id: String) -> Bool {
        guard let handle = handle else { return false }
        return id.withCString { cId in
            flow_delete_correction(handle, cId)
        }
    }

    /// Delete all corrections
    /// - Returns: The number of corrections deleted
    @discardableResult
    public func deleteAllCorrections() -> Int {
        guard let handle = handle else { return 0 }
        return flow_delete_all_corrections(handle)
    }

    /// Validate corrections using AI before learning
    /// - Parameter corrections: Array of (original, corrected) pairs to validate
    /// - Returns: Array of validation results, or nil on error
    public func validateCorrections(_ corrections: [(original: String, corrected: String)]) -> [CorrectionValidation]? {
        guard let handle = handle else { return nil }

        // Build JSON array
        let jsonArray: [[String: String]] = corrections.map { pair in
            ["original": pair.original, "corrected": pair.corrected]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return nil
        }

        let cResult = jsonString.withCString { cJson in
            flow_validate_corrections(handle, cJson)
        }

        guard let cString = cResult else { return nil }
        let resultString = String(cString: cString)
        flow_free_string(cString)

        guard let resultData = resultString.data(using: .utf8) else { return nil }

        struct RawValidation: Decodable {
            let original: String
            let corrected: String
            let valid: Bool
            let reason: String?
        }

        guard let rawResults = try? JSONDecoder().decode([RawValidation].self, from: resultData) else {
            return nil
        }

        return rawResults.map { raw in
            CorrectionValidation(
                original: raw.original,
                corrected: raw.corrected,
                valid: raw.valid,
                reason: raw.reason
            )
        }
    }

    // MARK: - Stats

    /// Get total transcription time in minutes
    public var totalTranscriptionMinutes: UInt64 {
        guard let handle = handle else { return 0 }
        return flow_total_transcription_minutes(handle)
    }

    /// Get total transcription count
    public var transcriptionCount: UInt64 {
        guard let handle = handle else { return 0 }
        return flow_transcription_count(handle)
    }

    // MARK: - App Tracking

    /// Set the currently active app
    /// - Parameters:
    ///   - appName: Name of the app
    ///   - bundleId: Optional bundle identifier
    ///   - windowTitle: Optional window title
    /// - Returns: Suggested writing mode for the app
    @discardableResult
    public func setActiveApp(name appName: String, bundleId: String? = nil, windowTitle: String? = nil) -> WritingMode {
        guard let handle = handle else { return .casual }

        let rawMode = appName.withCString { cName in
            if let bid = bundleId {
                return bid.withCString { cBid in
                    if let title = windowTitle {
                        return title.withCString { cTitle in
                            flow_set_active_app(handle, cName, cBid, cTitle)
                        }
                    } else {
                        return flow_set_active_app(handle, cName, cBid, nil)
                    }
                }
            } else {
                if let title = windowTitle {
                    return title.withCString { cTitle in
                        flow_set_active_app(handle, cName, nil, cTitle)
                    }
                } else {
                    return flow_set_active_app(handle, cName, nil, nil)
                }
            }
        }

        return WritingMode(rawValue: rawMode) ?? .casual
    }

    /// Get the current app's category
    public var currentAppCategory: AppCategory {
        guard let handle = handle else { return .unknown }
        let rawValue = flow_get_app_category(handle)
        return AppCategory(rawValue: rawValue) ?? .unknown
    }

    /// Get the current app name
    public var currentAppName: String? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_current_app(handle) else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    // MARK: - Style Learning

    /// Report edited text to learn user's style
    /// - Parameter editedText: The text after user edits
    /// - Returns: true on success
    public func learnStyle(editedText: String) -> Bool {
        guard let handle = handle else { return false }
        return editedText.withCString { cText in
            flow_learn_style(handle, cText)
        }
    }

    /// Get suggested mode based on learned style for current app
    /// - Returns: Suggested mode or nil if not enough data
    public var styleSuggestion: WritingMode? {
        guard let handle = handle else { return nil }
        let rawValue = flow_get_style_suggestion(handle)
        if rawValue == 255 { return nil }
        return WritingMode(rawValue: rawValue)
    }

    // MARK: - Extended Stats

    /// Get stats as a dictionary
    public var stats: [String: Any]? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_stats_json(handle) else { return nil }
        let jsonString = String(cString: cString)
        flow_free_string(cString)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Get recent transcriptions
    /// - Parameter limit: Maximum number of items to return
    public func recentTranscriptions(limit: Int = 50) -> [TranscriptionSummary] {
        guard let handle = handle else { return [] }
        guard let cString = flow_get_recent_transcriptions_json(handle, limit) else { return [] }
        let jsonString = String(cString: cString)
        flow_free_string(cString)

        guard let data = jsonString.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: dateString) {
                return date
            }

            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]
            if let date = standardFormatter.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date: \(dateString)"
            )
        }
        return (try? decoder.decode([TranscriptionSummary].self, from: data)) ?? []
    }

    /// Get the most recent error from the engine
    public var lastError: String? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_last_error(handle) else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    /// Get all shortcuts as array of dictionaries
    public var shortcuts: [[String: Any]]? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_shortcuts_json(handle) else { return nil }
        let jsonString = String(cString: cString)
        flow_free_string(cString)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        return json
    }

    // MARK: - Provider Configuration

    /// Switch the completion provider (loads API key from database)
    /// - Parameter provider: The provider to use
    /// - Returns: true on success
    public func switchCompletionProvider(_ provider: CompletionProvider) -> Bool {
        guard let handle = handle else { return false }
        return flow_switch_completion_provider(handle, provider.rawValue)
    }

    /// Set the completion provider with API key (saves both)
    /// - Parameters:
    ///   - provider: The provider to use
    ///   - apiKey: The API key for the provider
    /// - Returns: true on success
    public func setCompletionProvider(_ provider: CompletionProvider, apiKey: String) -> Bool {
        guard let handle = handle else { return false }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSet = trimmedKey.withCString { cKey in
            flow_set_completion_provider(handle, provider.rawValue, cKey)
        }

        return isSet
    }

    /// Get the current completion provider
    public var completionProvider: CompletionProvider? {
        guard let handle = handle else { return nil }
        let rawValue = flow_get_completion_provider(handle)
        return CompletionProvider(rawValue: rawValue)
    }

    /// Get API key for a specific provider in masked form
    /// - Parameter provider: The provider to get the key for
    /// - Returns: Masked API key (e.g., "sk-••••••••") or nil if not set
    public func getMaskedApiKey(for provider: CompletionProvider) -> String? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_api_key(handle, provider.rawValue) else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    /// Get the OpenAI API key in masked form (e.g., "sk-••••••••")
    /// - Returns: Masked API key or nil if not set
    public var maskedOpenAIKey: String? {
        getMaskedApiKey(for: .openAI)
    }

    /// Get the Gemini API key in masked form (e.g., "AI••••••••")
    /// - Returns: Masked API key or nil if not set
    public var maskedGeminiKey: String? {
        getMaskedApiKey(for: .gemini)
    }

    /// Get the OpenRouter API key in masked form
    /// - Returns: Masked API key or nil if not set
    public var maskedOpenRouterKey: String? {
        getMaskedApiKey(for: .openRouter)
    }

    /// Set transcription mode (local or remote)
    /// - Parameter mode: The transcription mode to use
    /// - Returns: true on success
    public func setTranscriptionMode(_ mode: TranscriptionMode) -> Bool {
        guard let handle = handle else { return false }

        switch mode {
        case let .local(model):
            return flow_set_transcription_mode(handle, true, model.rawValue)
        case .remote:
            return flow_set_transcription_mode(handle, false, 0) // model doesn't matter for remote
        }
    }

    /// Legacy: Enable local Whisper transcription with Metal acceleration
    /// - Parameter model: The Whisper model to use
    /// - Returns: true on success
    @available(*, deprecated, message: "Use setTranscriptionMode(.local(model:)) instead")
    public func enableLocalWhisper(_ model: WhisperModel) -> Bool {
        return setTranscriptionMode(.local(model: model))
    }

    /// Get current transcription mode settings from database
    /// - Returns: TranscriptionMode (local with model or remote), or nil on error
    public func getTranscriptionMode() -> TranscriptionMode? {
        guard let handle = handle else { return nil }

        var useLocal = false
        var whisperModel: UInt8 = 3 // default to quality

        guard flow_get_transcription_mode(handle, &useLocal, &whisperModel) else {
            return nil
        }

        if useLocal {
            let model = WhisperModel(rawValue: whisperModel) ?? .quality
            return .local(model: model)
        } else {
            return .remote
        }
    }

    /// Check if a Whisper model is currently being downloaded/initialized
    /// - Returns: true if model download is in progress
    public func isModelLoading() -> Bool {
        guard let handle = handle else { return false }
        return flow_is_model_loading(handle)
    }

    // MARK: - Cloud Transcription Provider

    /// Set the cloud transcription provider
    /// - Parameter provider: The cloud transcription provider to use
    /// - Returns: true on success
    public func setCloudTranscriptionProvider(_ provider: CloudTranscriptionProvider) -> Bool {
        guard let handle = handle else { return false }
        return flow_set_cloud_transcription_provider(handle, provider.rawValue)
    }

    /// Get the current cloud transcription provider
    public var cloudTranscriptionProvider: CloudTranscriptionProvider? {
        guard let handle = handle else { return nil }
        let rawValue = flow_get_cloud_transcription_provider(handle)
        return CloudTranscriptionProvider(rawValue: rawValue)
    }

    public var supportsRealtimeCloudSpeech: Bool {
        guard cloudTranscriptionProvider == .auto, case .remote? = getTranscriptionMode(),
              Locale.current.language.languageCode?.identifier == "en" else { return false }
        return true
    }

    // MARK: - Transcription Fallback

    /// Enable or disable the cloud fallback for local transcription.
    /// When enabled (default), a failing or empty local Whisper result is
    /// retried against the cloud so a dictation is never lost.
    /// - Parameter enabled: true to enable the fallback, false to disable
    /// - Returns: true on success
    @discardableResult
    public func setTranscriptionFallback(_ enabled: Bool) -> Bool {
        guard let handle = handle else { return false }
        return flow_set_transcription_fallback(handle, enabled)
    }

    /// Whether the cloud fallback for local transcription is enabled.
    public var transcriptionFallbackEnabled: Bool {
        guard let handle = handle else { return true }
        return flow_get_transcription_fallback(handle)
    }

    // MARK: - Style Learning

    private func takeString(_ cString: UnsafeMutablePointer<CChar>?) -> String? {
        guard let cString = cString else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    /// Format typed text as if it had been dictated
    public func formatText(_ text: String, appName: String?, contactName: String?) -> String? {
        guard let handle = handle else { return nil }
        return text.withCString { cText in
            withOptionalCString(appName) { cApp in
                withOptionalCString(contactName) { cContact in
                    takeString(flow_format_text(handle, cText, cApp, cContact))
                }
            }
        }
    }

    /// Record what the user finally sent for the last dictation
    /// - Parameter finalText: The sent text, or nil if it was unchanged
    /// - Returns: true when the style profile is due for a rebuild
    @discardableResult
    public func recordFinalText(_ finalText: String?) -> Bool {
        guard let handle = handle else { return false }
        return withOptionalCString(finalText) { flow_record_final_text(handle, $0) } == 1
    }

    /// The current Messages conversation, read through the native detector.
    public var activeMessagesContact: String? {
        MessagesContext.currentContact()
    }

    /// 0 = saved, 1 = saved and profile rebuild due, -1 = discarded because
    /// no completed baseline exists or the contact changed.
    public func recordFinalTextForContact(_ finalText: String?, contactName: String) -> Int32 {
        guard let handle else { return -1 }
        return withOptionalCString(finalText) { final in
            contactName.withCString { flow_record_final_text_for_contact(handle, final, $0) }
        }
    }

    /// Drop the last dictation without learning from it
    public func discardPendingDictation() {
        guard let handle = handle else { return }
        flow_discard_pending_dictation(handle)
    }

    /// Rebuild the style profile. Blocks on a network call, so call off the main thread.
    public func rebuildStyleProfile() -> Bool {
        guard let handle = handle else { return false }
        return flow_rebuild_style_profile(handle)
    }

    /// Markdown style profile, empty when none has been built
    public var styleProfile: String {
        guard let handle = handle else { return "" }
        return takeString(flow_get_style_profile(handle)) ?? ""
    }

    @discardableResult
    public func setStyleProfile(_ profile: String) -> Bool {
        guard let handle = handle else { return false }
        return profile.withCString { flow_set_style_profile(handle, $0) }
    }

    public var rewriteStrength: RewriteStrength {
        get {
            guard let handle = handle else { return .balanced }
            return RewriteStrength(rawValue: flow_get_rewrite_strength(handle)) ?? .balanced
        }
        set {
            guard let handle = handle else { return }
            _ = flow_set_rewrite_strength(handle, newValue.rawValue)
        }
    }

    public var styleStats: StyleStats? {
        guard let handle = handle,
              let json = takeString(flow_get_style_stats_json(handle)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StyleStats.self, from: data)
    }

    /// Import messages sent from the Messages app. Blocks while reading, so call off the main thread.
    /// - Returns: Number imported, or nil on error (see `lastError`)
    public func importIMessages(limit: UInt32 = 5000) -> Int? {
        guard let handle = handle else { return nil }
        let count = flow_import_imessages(handle, limit)
        return count < 0 ? nil : Int(count)
    }

    @discardableResult
    public func resetStyleLearning() -> Bool {
        guard let handle = handle else { return false }
        return flow_reset_style_learning(handle)
    }

    private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string = string else { return body(nil) }
        return string.withCString { body($0) }
    }

    // MARK: - OpenAI Base URL

    /// Set a custom OpenAI-compatible base URL for transcription
    /// - Parameter url: The base URL (e.g. "http://localhost:8080/v1"). Pass empty string to reset to default.
    /// - Returns: true on success
    @discardableResult
    public func setOpenAIBaseURL(_ url: String) -> Bool {
        guard let handle = handle else { return false }
        return url.withCString { cURL in
            flow_set_openai_base_url(handle, cURL)
        }
    }

    /// Get the currently configured custom OpenAI base URL
    /// - Returns: The custom URL, or nil if using the default (https://api.openai.com/v1)
    public var openAIBaseURL: String? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_openai_base_url(handle) else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    // MARK: - Auto-Rewriting

    /// Set whether auto-rewriting is enabled
    /// When disabled, transcriptions are returned as-is (with shortcuts only, no corrections or AI)
    /// - Parameter enabled: Whether auto-rewriting should be enabled
    /// - Returns: true on success
    @discardableResult
    public func setAutoRewritingEnabled(_ enabled: Bool) -> Bool {
        guard let handle = handle else { return false }
        return flow_set_auto_rewriting_enabled(handle, enabled)
    }

    /// Get whether auto-rewriting is enabled
    /// When disabled, transcriptions are returned as-is (with shortcuts only, no corrections or AI)
    public var isAutoRewritingEnabled: Bool {
        guard let handle = handle else { return true }
        return flow_get_auto_rewriting_enabled(handle)
    }

    // MARK: - Alignment and Edit Detection

    /// Align original and edited text, extract correction candidates
    /// Uses Needleman-Wunsch algorithm with word-level scoring
    /// - Parameters:
    ///   - original: The original text
    ///   - edited: The edited text
    /// - Returns: JSON string with alignment result, or nil on error
    public func alignAndExtractCorrections(original: String, edited: String) -> String? {
        let result = original.withCString { cOriginal in
            edited.withCString { cEdited in
                flow_align_and_extract_corrections(cOriginal, cEdited)
            }
        }

        guard let cString = result else { return nil }
        let string = String(cString: cString)
        flow_free_string(cString)
        return string
    }

    /// Get dictionary context for ASR vocabulary prompting
    /// - Parameter limit: Maximum number of words to return
    /// - Returns: Array of high-confidence learned words
    public func getDictionaryContext(limit: Int = 100) -> [String] {
        guard let handle = handle else { return [] }
        guard let cString = flow_get_dictionary_context(handle, UInt32(limit)) else { return [] }
        let jsonString = String(cString: cString)
        flow_free_string(cString)

        guard let data = jsonString.data(using: .utf8),
              let words = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return words
    }

    /// Save edit analytics for tracking alignment patterns
    /// - Parameters:
    ///   - wordEditVector: The word-level edit vector (e.g., "MMSMM")
    ///   - punctEditVector: The punctuation edit vector
    ///   - original: The original text (optional)
    ///   - edited: The edited text (optional)
    /// - Returns: true on success
    @discardableResult
    public func saveEditAnalytics(
        wordEditVector: String,
        punctEditVector: String?,
        original: String?,
        edited: String?
    ) -> Bool {
        guard let handle = handle else { return false }

        return wordEditVector.withCString { cWordVec in
            withOptionalCString(punctEditVector) { punctPtr in
                withOptionalCString(original) { origPtr in
                    withOptionalCString(edited) { editPtr in
                        flow_save_edit_analytics(handle, cWordVec, punctPtr, origPtr, editPtr)
                    }
                }
            }
        }
    }

    /// Save a learned words session for undo functionality
    /// - Parameter words: Array of words that were learned
    /// - Returns: Session ID (or -1 on error)
    @discardableResult
    public func saveLearnedWordsSession(words: [String]) -> Int64 {
        guard let handle = handle else { return -1 }

        guard let jsonData = try? JSONEncoder().encode(words),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return -1
        }

        return jsonString.withCString { cJson in
            flow_save_learned_words_session(handle, cJson)
        }
    }

    /// Undo the most recent learned words session
    /// - Returns: true if undo was performed
    @discardableResult
    public func undoLearnedWords() -> Bool {
        guard let handle = handle else { return false }
        return flow_undo_learned_words(handle)
    }

    /// Get the most recent undoable learned words
    /// - Returns: Array of words, or nil if no undoable session exists
    public func getUndoableLearnedWords() -> [String]? {
        guard let handle = handle else { return nil }
        guard let cString = flow_get_undoable_learned_words(handle) else { return nil }

        let jsonString = String(cString: cString)
        flow_free_string(cString)

        guard let data = jsonString.data(using: .utf8),
              let words = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        return words
    }

    // Configuration persistence is handled in the core database.
}

/// How far the formatter may move away from the user's own words
public enum RewriteStrength: UInt8, Sendable, CaseIterable {
    case light = 0
    case balanced = 1
    case full = 2

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .full: return "Full"
        }
    }

    public var description: String {
        switch self {
        case .light: return "Only removes filler words and fixes punctuation"
        case .balanced: return "Adjusts tone, keeps most of your words"
        case .full: return "Rewrites freely in your style"
        }
    }
}

/// How often you change Flow's output before sending
public struct StyleStats: Decodable, Sendable {
    public let edited: Int
    public let total: Int
    public let rate: Double
    public let recentEdited: Int
    public let recentTotal: Int
    public let recentRate: Double
    public let examples: Int

    enum CodingKeys: String, CodingKey {
        case edited, total, rate, examples
        case recentEdited = "recent_edited"
        case recentTotal = "recent_total"
        case recentRate = "recent_rate"
    }
}
