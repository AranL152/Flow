import Foundation

@main
struct HelperLifecycleCheck {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fixture(_ name: String, body: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let code = "#!/usr/bin/python3\nimport sys\nwith open(__file__ + '.count', 'a') as f: f.write('1\\n')\n" + body
            try code.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        func starts(_ url: URL) -> Int {
            (try? String(contentsOfFile: url.path + ".count"))?.split(separator: "\n").count ?? 0
        }
        var checks: [String: Bool] = [:]
        let deniedURL = try fixture("denied", body: "print('{\"event\":\"error\",\"message\":\"Accessibility permission not granted\"}', flush=True)\n")
        var errors: [String] = []
        let blocked = HelperManager(helperURL: deniedURL, hasAccessibilityAccess: { false })
        blocked.onError = { errors.append($0) }
        blocked.start()
        try await Task.sleep(for: .milliseconds(200))
        checks["denied_parent_does_not_spawn_or_prompt"] = starts(deniedURL) == 0 && errors.count == 1 && !blocked.isRunning
        blocked.stop()
        errors = []
        let denied = HelperManager(helperURL: deniedURL, hasAccessibilityAccess: { true })
        denied.onError = { errors.append($0) }
        denied.start()
        try await Task.sleep(for: .milliseconds(1400))
        checks["helper_permission_error_does_not_retry"] = starts(deniedURL) == 1 && errors.count == 1 && !denied.isRunning
        denied.stop()

        let crashURL = try fixture("crash", body: "sys.exit(1)\n")
        let cancelled = HelperManager(helperURL: crashURL, hasAccessibilityAccess: { true })
        cancelled.start()
        try await Task.sleep(for: .milliseconds(200))
        cancelled.stop()
        try await Task.sleep(for: .milliseconds(1300))
        checks["stop_cancels_pending_restart"] = starts(crashURL) == 1 && !cancelled.isRunning

        let stableURL = try fixture("stable", body: "print('{\"event\":\"ready\"}', flush=True)\nfor line in sys.stdin:\n    if 'quit' in line: break\n")
        let stable = HelperManager(helperURL: stableURL, hasAccessibilityAccess: { true })
        var ready = 0
        stable.onReady = { ready += 1 }
        stable.start()
        try await Task.sleep(for: .milliseconds(200))
        stable.stop(); stable.start()
        try await Task.sleep(for: .milliseconds(1300))
        checks["old_exit_does_not_clear_replacement"] = stable.isRunning && ready == 2 && starts(stableURL) == 2
        stable.stop()

        let budgetURL = try fixture("budget", body: "sys.exit(1)\n")
        errors = []
        let budget = HelperManager(helperURL: budgetURL, hasAccessibilityAccess: { true })
        budget.onError = { errors.append($0) }
        budget.start()
        try await Task.sleep(for: .seconds(6.8))
        checks["eof_and_exit_use_one_restart_budget"] = starts(budgetURL) == 6 && errors == ["Helper crashed too many times"] && !budget.isRunning
        budget.stop()
        let passed = checks.count == 5 && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["passed": passed, "checks": checks,
            "scope": "Production helper lifecycle with synthetic child processes and injected access checks. No event taps, permission prompts, microphone capture or Messages changes. Physical Fn input and macOS grants were not tested."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "review/helper-lifecycle-verification.json"))
        print(String(decoding: data, as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
