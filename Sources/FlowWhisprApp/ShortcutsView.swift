//
// ShortcutsView.swift
// FlowWhispr
//
// Voice shortcuts management interface.
//

import SwiftUI

struct ShortcutsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newTrigger = ""
    @State private var newReplacement = ""
    @State private var shortcuts: [ShortcutItem] = []
    @State private var showingAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // toolbar
            HStack {
                Text("Voice Shortcuts")
                    .font(.headline)
                Spacer()
                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
            }
            .padding()

            Divider()

            // list
            if shortcuts.isEmpty {
                ContentUnavailableView {
                    Label("No Shortcuts", systemImage: "text.badge.plus")
                } description: {
                    Text("Add shortcuts to quickly expand phrases while dictating.")
                } actions: {
                    Button("Add Shortcut") {
                        showingAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shortcuts) { shortcut in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(shortcut.trigger)
                                    .font(.headline)
                                Text(shortcut.replacement)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            if shortcut.useCount > 0 {
                                Text("\(shortcut.useCount) uses")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            Button(action: { deleteShortcut(shortcut) }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 480, height: 400)
        .sheet(isPresented: $showingAddSheet) {
            AddShortcutSheet(
                trigger: $newTrigger,
                replacement: $newReplacement,
                onAdd: addShortcut,
                onCancel: { showingAddSheet = false }
            )
        }
        .onAppear {
            refreshShortcuts()
        }
    }

    private func refreshShortcuts() {
        if let raw = appState.engine.shortcuts {
            shortcuts = raw.compactMap { dict in
                guard let trigger = dict["trigger"] as? String,
                      let replacement = dict["replacement"] as? String else {
                    return nil
                }
                let useCount = dict["use_count"] as? Int ?? 0
                return ShortcutItem(trigger: trigger, replacement: replacement, useCount: useCount)
            }
        }
    }

    private func addShortcut() {
        guard !newTrigger.isEmpty, !newReplacement.isEmpty else { return }

        if appState.addShortcut(trigger: newTrigger, replacement: newReplacement) {
            refreshShortcuts()
            newTrigger = ""
            newReplacement = ""
            showingAddSheet = false
        }
    }

    private func deleteShortcut(_ shortcut: ShortcutItem) {
        if appState.removeShortcut(trigger: shortcut.trigger) {
            refreshShortcuts()
        }
    }
}

// MARK: - Supporting Types

struct ShortcutItem: Identifiable {
    let id = UUID()
    let trigger: String
    let replacement: String
    let useCount: Int
}

struct AddShortcutSheet: View {
    @Binding var trigger: String
    @Binding var replacement: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Voice Shortcut")
                .font(.headline)

            Form {
                TextField("Trigger phrase", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                TextField("Replacement text", text: $replacement)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trigger.isEmpty || replacement.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

#Preview {
    ShortcutsView()
        .environmentObject(AppState())
}
