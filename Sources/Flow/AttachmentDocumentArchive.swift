import Foundation

/// macOS's bundled ZIP reader; no shell, extraction directory, scripts, office
/// automation or new dependencies. Output, runtime and cancellation are bounded.
enum AttachmentDocumentArchive {
    private final class Running: @unchecked Sendable {
        let lock = NSLock()
        var process: Process?
        var stopped = false
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { throw CancellationError() }
            self.process = process
            try process.run()
        }
        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    static func read(_ url: URL, entry: String?, limit: Int, deadline: Date) async throws -> Data {
        let running = Running()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process(), output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = entry.map { ["-p", url.path, $0] } ?? ["-Z1", url.path]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    let delay = min(2, max(0, deadline.timeIntervalSinceNow))
                    let timeout = DispatchWorkItem { running.stop() }
                    do {
                        guard delay > 0 else { throw AttachmentFailure.unavailable("Document read timed out.") }
                        try running.start(process)
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: timeout)
                        var data = Data()
                        while let chunk = try output.fileHandleForReading.read(upToCount: min(65536, limit + 1 - data.count)), !chunk.isEmpty {
                            data.append(chunk)
                            guard data.count <= limit else {
                                running.stop()
                                throw AttachmentFailure.unavailable("Presentation entry exceeds the local search limit.")
                            }
                        }
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw AttachmentFailure.unavailable("Couldn't read presentation archive.") }
                        timeout.cancel()
                        continuation.resume(returning: data)
                    } catch {
                        timeout.cancel(); running.stop(); process.waitUntilExitIfRunning()
                        continuation.resume(throwing: error)
                    }
                    try? output.fileHandleForReading.close()
                }
            }
        } onCancel: { running.stop() }
    }
}

private extension Process {
    func waitUntilExitIfRunning() { if isRunning { waitUntilExit() } }
}
