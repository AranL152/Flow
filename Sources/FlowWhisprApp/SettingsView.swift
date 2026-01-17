//
// SettingsView.swift
// FlowWhispr
//
// Settings window.
//

import FlowWhispr
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            APISettingsView()
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }

            KeyboardSettingsView()
                .tabItem {
                    Label("Keyboard", systemImage: "keyboard")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("defaultMode") private var defaultMode = 1

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("Feedback") {
                Toggle("Play sounds", isOn: $playSounds)
            }

            Section("Default Writing Mode") {
                Picker("Mode", selection: $defaultMode) {
                    ForEach(WritingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(Int(mode.rawValue))
                    }
                }
                .pickerStyle(.segmented)

                if let mode = WritingMode(rawValue: UInt8(defaultMode)) {
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - API Settings

struct APISettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var selectedProvider = 0

    var body: some View {
        Form {
            Section("Transcription (OpenAI Whisper)") {
                SecureField("OpenAI API Key", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    appState.setApiKey(openAIKey)
                }
                .disabled(openAIKey.isEmpty)
            }

            Section("Completion Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    Text("OpenAI GPT").tag(0)
                    Text("Anthropic Claude").tag(1)
                }
                .pickerStyle(.segmented)

                if selectedProvider == 1 {
                    SecureField("Anthropic API Key", text: $anthropicKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        appState.setAnthropicKey(anthropicKey)
                    }
                    .disabled(anthropicKey.isEmpty)
                }
            }

            Section {
                HStack {
                    Image(systemName: appState.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(appState.isConfigured ? .green : .orange)
                    Text(appState.isConfigured ? "API configured" : "API key required")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Keyboard Settings

struct KeyboardSettingsView: View {
    var body: some View {
        Form {
            Section("Recording Shortcut") {
                KeyboardShortcuts.Recorder("Toggle Recording", name: .toggleRecording)
            }

            Section {
                Text("Press the shortcut to start recording. Press again to stop and transcribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("FlowWhispr")
                .font(.title)
                .fontWeight(.semibold)

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Voice dictation powered by AI")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://flowwhispr.app")!)
                Link("GitHub", destination: URL(string: "https://github.com/json/flowwhispr")!)
            }
            .font(.caption)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
