//
// TranscriptionSummary.swift
// FlowWhispr
//
// Lightweight transcription summary for history views.
//

import Foundation

public enum TranscriptionStatus: String, Codable {
    case success
    case failed
}

public struct TranscriptionSummary: Identifiable, Codable {
    public let id: String
    public let status: TranscriptionStatus
    public let text: String
    public let error: String?
    public let durationMs: UInt64
    public let createdAt: Date
    public let appName: String?

    public init(
        id: String,
        status: TranscriptionStatus,
        text: String,
        error: String?,
        durationMs: UInt64,
        createdAt: Date,
        appName: String?
    ) {
        self.id = id
        self.status = status
        self.text = text
        self.error = error
        self.durationMs = durationMs
        self.createdAt = createdAt
        self.appName = appName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case text
        case error
        case durationMs = "duration_ms"
        case createdAt = "created_at"
        case appName = "app_name"
    }
}
