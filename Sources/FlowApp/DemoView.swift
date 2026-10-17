import SwiftUI

struct DemoView: View {
    @StateObject private var model = FlowDemoModel()
    @State private var showReset = false
    private let colors: [Color] = [Color(red: 0.57, green: 0.61, blue: 1), Color(red: 1, green: 0.57, blue: 0.67), Color(red: 0.35, green: 0.81, blue: 0.76)]
    private let surface = Color(red: 0.09, green: 0.10, blue: 0.13)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                input.padding(.top, 18)
                connections.frame(height: 48)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(model.recipients.enumerated()), id: \.element.id) { index, person in
                        recipient(person, color: colors[index % colors.count])
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: model.isGenerating ? "sparkles" : "checkmark.circle")
                    Text(model.activity).contentTransition(.opacity)
                    Spacer()
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                .padding(.top, 12)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }
                Text("Synthetic conversations · Send saves here only · Edits are examples for a context, not permanent rules")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.top, 12)
            }
            .padding(24)
            .frame(minWidth: 860, maxWidth: 1250)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.045, green: 0.05, blue: 0.07))
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .onDisappear { model.shutdown() }
        .confirmationDialog("Reset these demo conversations?", isPresented: $showReset) {
            Button("Reset demo history", role: .destructive) { model.reset() }
        } message: { Text("This removes the edits learned in this demo. Your real Flow history is unaffected.") }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform").foregroundStyle(colors[0])
                    Text("FLOW / CONVERSATIONS").tracking(3).foregroundStyle(.white.opacity(0.5))
                }.font(.system(size: 10, weight: .semibold))
                Text("One voice. Still you.").font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-1)
                Text("Learned from how you actually write to each person.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button { showReset = true } label: { Label("Reset demo", systemImage: "arrow.counterclockwise") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                .padding(.top, 8)
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.isRecording ? "LISTENING" : "YOUR WORDS", systemImage: model.isRecording ? "mic.fill" : "waveform")
                    .font(.system(size: 10, weight: .semibold)).tracking(2)
                    .foregroundStyle(model.isRecording ? colors[1] : .white.opacity(0.55))
                Spacer()
                if model.isRecording {
                    HStack(spacing: 3) {
                        ForEach(0..<20) { i in
                            Capsule().fill(colors[0]).frame(width: 3, height: 3 + CGFloat(model.audioLevel) * CGFloat(8 + (i * 7) % 19))
                        }
                    }.frame(height: 24).animation(.linear(duration: 0.08), value: model.audioLevel)
                }
            }
            ZStack(alignment: .topLeading) {
                if model.transcript.isEmpty {
                    Text("Say something, or type your message here…")
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.22)).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: $model.transcript).font(.system(size: 22, weight: .medium))
                    .scrollContentBackground(.hidden).frame(height: 48)
                    .disabled(model.isRecording)
                    .accessibilityLabel("Spoken or typed message")
            }
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.white.opacity(0.4))
                Text("Context").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                TextField("Conversation context", text: $model.context)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    .accessibilityLabel("Conversation context").frame(maxWidth: 260)
                    .disabled(model.isRecording)
                Spacer()
                Button { model.isRecording ? model.stopRecording() : model.startRecording() } label: {
                    Label(model.isRecording ? "Finish" : "Speak", systemImage: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(model.isRecording ? colors[1].opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain)
                Button { model.generate() } label: {
                    Label("Generate", systemImage: "arrow.down")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(colors[0].opacity(0.25), in: Capsule())
                }.buttonStyle(.plain).disabled(model.isRecording || model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).background(surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
    }

    private var connections: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isGenerating)) { timeline in
            Canvas { context, size in
                let start = CGPoint(x: size.width / 2, y: 0)
                for i in 0..<3 {
                    let end = CGPoint(x: size.width * CGFloat(2 * i + 1) / 6, y: size.height)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: size.height * 0.65), control2: CGPoint(x: end.x, y: size.height * 0.35))
                    context.stroke(path, with: .color(colors[i].opacity(0.25)), lineWidth: 1)
                    if model.isGenerating {
                        let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5)
                        context.stroke(path.trimmedPath(from: max(0, phase - 0.16), to: phase), with: .color(colors[i]), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 6, width: 6, height: 6)), with: .color(colors[i]))
                }
            }
        }.accessibilityHidden(true)
    }

    private func recipient(_ person: DemoRecipient, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String(person.name.prefix(1))).font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38).background(color.opacity(0.15), in: Circle()).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name).font(.system(size: 16, weight: .semibold))
                    Text(person.role).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if person.status == "generating" { ProgressView().controlSize(.small).tint(color) }
                if person.status == "sent" { Image(systemName: "checkmark.circle.fill").foregroundStyle(color) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Label("FROM YOUR HISTORY", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(color.opacity(0.8))
                ForEach(Array(person.history.suffix(2).enumerated()), id: \.offset) { _, text in
                    Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
            }.frame(height: 90, alignment: .top)
            Rectangle().fill(color.opacity(0.15)).frame(height: 1)
            HStack {
                Text(person.status == "sent" ? "SENT IN DEMO" : (person.status == "listening" ? "LIVE PREVIEW" : "YOUR DRAFT"))
                    .font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(color)
                Spacer()
                if person.evidenceCount > 0 { Text("\(person.evidenceCount) memories used").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)) }
            }
            ZStack(alignment: .topLeading) {
                if person.draft.isEmpty { Text("Your words arrive here").font(.system(size: 16)).foregroundStyle(.white.opacity(0.18)).padding(5) }
                TextEditor(text: Binding(get: { person.draft }, set: { model.setDraft(id: person.id, text: $0) }))
                    .font(.system(size: 16)).scrollContentBackground(.hidden).frame(height: 68)
                    .disabled(person.status != "ready").accessibilityLabel("Draft for \(person.name)")
            }
            HStack {
                Text(person.preservedOriginal ? "Original kept · detail check" : (person.status == "ready" ? "Edit before sending" : person.status.capitalized))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.3)) { model.send(id: person.id) } } label: {
                    Label("Send", systemImage: "arrow.up").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8).background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
                }.buttonStyle(.plain).disabled(person.status != "ready" || person.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRecording)
            }
            if let note = person.memory.last {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(note.edited ? "EDIT REMEMBERED" : "MESSAGE REMEMBERED", systemImage: "brain.head.profile")
                            .font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(color)
                        Spacer()
                        Button("Forget") { model.forget(recipientID: person.id, noteID: note.id) }
                            .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    }
                    Text(note.context).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    if note.edited {
                        Text(note.before).strikethrough().foregroundStyle(.white.opacity(0.35)).font(.system(size: 11)).lineLimit(2)
                        Image(systemName: "arrow.down").font(.system(size: 9)).foregroundStyle(color)
                    }
                    Text(note.after).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                }.padding(12).background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(person.status == "sent" ? 0.5 : 0.15)))
    }
}
