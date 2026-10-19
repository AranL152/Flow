import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// Explicit diagnostics in the actual signed app, without recording audio,
/// inference, hotkeys, contact access or changes to a Messages draft.
@MainActor
enum NativePrivacyAudit {
    static func run() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let initialMicrophone = AVCaptureDevice.authorizationStatus(for: .audio)
        let requesting = arguments.contains("--request-microphone") && initialMicrophone == .notDetermined
        if requesting { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        var fileReadable: Bool?
        if let path = value("--privacy-read-file") {
            do {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                fileReadable = try file.read(upToCount: 1)?.isEmpty == false
            } catch { fileReadable = false }
        }
        var desktopReadable: Bool?
        if arguments.contains("--privacy-read-desktop") {
            do {
                let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: false)
                _ = try FileManager.default.contentsOfDirectory(at: desktop, includingPropertiesForKeys: nil)
                desktopReadable = true
            } catch { desktopReadable = false }
        }
        let report: [String: Any] = [
            "scope": "Actual signed app permissions; no audio recording, model calls or Messages changes.",
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "FlowBuildCommit") as? String ?? "",
            "accessibility_authorized": AXIsProcessTrusted(),
            "microphone_authorized": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "microphone_request_made": requesting,
            "file_readable": fileReadable as Any? ?? NSNull(),
            "desktop_directory_readable": desktopReadable as Any? ?? NSNull()
        ]
        if let output = value("--privacy-report"),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
