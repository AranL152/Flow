import AppKit
import Flow
import SwiftUI
@testable import FlowApp

// Visual preview only. This never starts recording, inserts text, or reads Messages.
@MainActor
final class CaptionPlacementPreview: ObservableObject {
    let state = AppState()
    @Published var atTop = false
    @Published var expanded = false
    @Published var draft = ""
    @Published var phase = "Live captions"
    private var playback: Task<Void, Never>?

    func replay() {
        playback?.cancel()
        playback = Task { @MainActor [weak self] in
            guard let self else { return }
            state.isRecording = true
            state.isProcessing = false
            state.liveTranscriptFinalized = false
            state.captionPresentationActive = false
            state.liveTranscript = ""
            draft = ""
            phase = "Live captions"
            let speech = "Yo, can you check out this deck when you get a sec? Let me know what you think."
            let output = "Could you review this deck when you have a moment? I would appreciate your feedback."
            do {
                for (index, character) in speech.enumerated() {
                    try Task.checkCancellation()
                    state.liveTranscript.append(character)
                    state.recordingDuration = UInt64(index * 55)
                    state.smoothedAudioLevel = Float(0.2 + 0.45 * abs(sin(Double(index) * 0.4)))
                    try await Task.sleep(for: .milliseconds(character == " " ? 75 : 42))
                }
                try await Task.sleep(for: .milliseconds(650))
                state.isRecording = false
                state.isProcessing = true
                phase = "Rewritten draft"
                for character in output {
                    try Task.checkCancellation()
                    draft.append(character)
                    try await Task.sleep(for: .milliseconds(24))
                }
                phase = "Move the composer to see captions reposition"
            } catch { /* Replay cancels the previous visual sequence. */ }
        }
    }
}

struct CaptionPlacementScene: View {
    @ObservedObject var model: CaptionPlacementPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Captions that stay out of your way").font(.title3.weight(.semibold))
                    Text("Silent preview · simulated text · no microphone or API calls")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Replay") { model.replay() }
            }.padding(20)
            Divider()
            GeometryReader { geometry in
                let size = geometry.size
                let height: CGFloat = model.expanded ? 160 : 74
                // The placement engine uses AppKit coordinates, measured from the bottom.
                let composer = CGRect(x: 50, y: model.atTop ? size.height - height - 28 : 28,
                                      width: max(240, size.width - 100), height: height)
                let placement = DictationOverlayPlacement.place(
                    size: CGSize(width: 500, height: 190), composer: composer,
                    screens: [CGRect(origin: .zero, size: size)])
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .controlBackgroundColor)
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 32)).foregroundStyle(.secondary.opacity(0.35))
                        Text("Message composer stays visible")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24)).foregroundStyle(.secondary.opacity(0.6))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message composer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(model.draft.isEmpty ? "Rewritten output appears here…" : model.draft)
                                .font(.system(size: 15))
                                .foregroundStyle(model.draft.isEmpty ? Color.secondary : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26)).foregroundStyle(.blue)
                            .accessibilityLabel("Decorative send icon; sending is disabled")
                    }
                    .padding(14)
                    .frame(width: composer.width, height: composer.height, alignment: .topLeading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.14)))
                    .position(x: composer.midX, y: size.height - composer.midY)

                    RecordingIndicatorView()
                        .environmentObject(model.state)
                        .frame(width: placement.frame.width, height: placement.frame.height)
                        .position(x: placement.frame.midX, y: size.height - placement.frame.midY)
                        .allowsHitTesting(false)
                }
                .clipped()
            }
            Divider()
            HStack(spacing: 16) {
                Picker("Composer", selection: $model.atTop) {
                    Text("Bottom").tag(false)
                    Text("Top").tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
                Toggle("Expand draft", isOn: $model.expanded).toggleStyle(.checkbox)
                Spacer()
                Text(model.phase).font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
        .frame(minWidth: 760, minHeight: 600)
    }
}

struct MessagesCaptionControls: View {
    @ObservedObject var model: CaptionPlacementPreview
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.slash.fill").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Silent Messages preview").font(.system(size: 13, weight: .semibold))
                Text("Simulated captions · your draft stays unchanged")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Replay") { model.replay() }
            Button("Close") { NSApplication.shared.terminate(nil) }
        }.padding(14)
    }
}

@main
struct CaptionPlacementRunner {
    @MainActor private static var window: NSWindow?
    @MainActor private static var model: CaptionPlacementPreview?
    @MainActor private static var indicator: RecordingIndicatorWindow?
    @MainActor static func main() {
        // AppState's simulation mode disables global hotkeys and production observers.
        guard ProcessInfo.processInfo.arguments.contains("--voice-simulation") else { return }
        let app = NSApplication.shared
        let messagesPreview = ProcessInfo.processInfo.arguments.contains("--messages")
        app.setActivationPolicy(messagesPreview ? .accessory : .regular)
        let model = CaptionPlacementPreview()
        Self.model = model
        if messagesPreview {
            Task { @MainActor in
                guard let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
                    fputs("Messages must be open with a conversation selected.\n", stderr)
                    app.terminate(nil); return
                }
                messages.activate(options: [.activateAllWindows])
                try? await Task.sleep(for: .milliseconds(350))
                guard let anchor = RecordingComposerAnchor(app: messages), anchor.frame != nil else {
                    fputs("Cannot locate the Messages composer; no draft was changed.\n", stderr)
                    app.terminate(nil); return
                }
                let indicator = RecordingIndicatorWindow(appState: model.state)
                Self.indicator = indicator
                indicator.prepare(near: messages)
                model.replay()
                indicator.show(near: messages)
                let controls = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 65),
                    styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
                controls.title = "Flow · Silent preview"
                controls.contentView = NSHostingView(rootView: MessagesCaptionControls(model: model))
                controls.level = .floating
                controls.hidesOnDeactivate = false
                controls.isReleasedWhenClosed = false
                if let screen = NSScreen.main {
                    controls.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 24,
                                                         y: screen.visibleFrame.maxY - 24))
                }
                controls.orderFrontRegardless()
                Self.window = controls
                print("Silent captions are anchored to the actual Messages composer. No audio or draft writes.")
            }
            app.run()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Flow · Silent caption placement preview"
        window.contentView = NSHostingView(rootView: CaptionPlacementScene(model: model))
        window.minSize = NSSize(width: 780, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
        app.activate(ignoringOtherApps: true)
        model.replay()
        app.run()
    }
}
