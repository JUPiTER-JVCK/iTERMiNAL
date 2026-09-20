import SwiftUI

/// Settings → AI: OpenAI-compatible endpoint, model, keychain-backed API key,
/// and which bits of terminal context travel with a prompt.
struct AISettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var apiKeyDraft = ""
    @State private var keyMessage: String?
    @State private var providerPreset: ProviderPreset = .openai

    private enum ProviderPreset: String, CaseIterable, Identifiable {
        case openai, ollama, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .openai: return "OpenAI"
            case .ollama: return "Ollama (local)"
            case .custom: return "Custom"
            }
        }

        var baseURL: String? {
            switch self {
            case .openai: return "https://api.openai.com/v1"
            case .ollama: return "http://127.0.0.1:11434/v1"
            case .custom: return nil
            }
        }
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $providerPreset) {
                    ForEach(ProviderPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: providerPreset) { _, preset in
                    if let url = preset.baseURL {
                        settings.assistantBaseURL = url
                    }
                }

                TextField("Base URL", text: $settings.assistantBaseURL)
                    .disabled(providerPreset != .custom && providerPreset.baseURL != nil)
                    .onChange(of: settings.assistantBaseURL) { _, newValue in
                        // Keep the preset in sync when the URL was edited
                        // elsewhere or loaded from preferences.
                        if newValue == ProviderPreset.openai.baseURL {
                            providerPreset = .openai
                        } else if newValue == ProviderPreset.ollama.baseURL {
                            providerPreset = .ollama
                        } else if providerPreset != .custom {
                            providerPreset = .custom
                        }
                    }

                TextField("Model", text: $settings.assistantModel)
                Text("OpenAI-compatible chat completions at `{base}/chat/completions`. Point the base URL at Ollama or any compatible proxy for local models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API key") {
                if hasSavedKey {
                    LabeledContent("Status", value: "Key saved in keychain")
                } else if OpenAICompatibleAssistant.isLocalHost(settings.assistantBaseURL) {
                    LabeledContent("Status", value: "Not required for localhost")
                } else {
                    LabeledContent("Status", value: "Not set")
                }

                SecureField("API key", text: $apiKeyDraft)
                HStack {
                    Button("Save Key") { saveKey() }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear Key", role: .destructive) { clearKey() }
                        .disabled(!hasSavedKey)
                }
                if let keyMessage {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The key is write-only: it lives in the keychain under `assistant.apiKey` and is never stored in preferences or export snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Context") {
                Toggle("Include working directory", isOn: $settings.assistantIncludeCwd)
                Toggle("Include recent terminal output", isOn: $settings.assistantIncludeRecentOutput)
                Toggle("Include git branch", isOn: $settings.assistantIncludeGitBranch)
                Text("Only these fields are sent with a prompt. Full scrollback and secrets are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("""
                Prompts and the context toggles above go to the configured endpoint when you submit `@ai …` in the composer. Nothing is sent until an API key is saved (or the base URL is a localhost OpenAI-compatible server). Suggested commands are shown only — they are never auto-executed.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if settings.assistantBaseURL == ProviderPreset.ollama.baseURL {
                providerPreset = .ollama
            } else if settings.assistantBaseURL == ProviderPreset.openai.baseURL {
                providerPreset = .openai
            } else {
                providerPreset = .custom
            }
        }
    }

    private var hasSavedKey: Bool {
        let key = KeychainStore.get(OpenAICompatibleAssistant.apiKeyAccount) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, for: OpenAICompatibleAssistant.apiKeyAccount) {
            apiKeyDraft = ""
            keyMessage = "Key saved."
        } else {
            keyMessage = "Couldn't save the key to your keychain."
        }
    }

    private func clearKey() {
        KeychainStore.delete(OpenAICompatibleAssistant.apiKeyAccount)
        apiKeyDraft = ""
        keyMessage = "Key cleared."
    }
}
