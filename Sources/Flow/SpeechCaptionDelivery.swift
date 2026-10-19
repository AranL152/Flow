import Foundation

/// A final segment and its revised interim tail can arrive in the same burst.
/// Present their newest combined text once, avoiding a brief backwards jump.
@MainActor
final class SpeechCaptionDelivery {
    var onText: ((String) -> Void)?
    private var pending: Task<Void, Never>?
    private var generation = UUID()

    func submit(_ text: String) {
        pending?.cancel()
        let epoch = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self, self.generation == epoch else { return }
            self.onText?(text)
            self.pending = nil
        }
    }

    func cancel() {
        generation = UUID(); pending?.cancel(); pending = nil
    }
}
