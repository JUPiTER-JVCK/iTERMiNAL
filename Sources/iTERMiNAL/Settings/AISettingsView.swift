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
                Toggle("Include git branch", isOn: $settings.assistantIncludeGitBranch)
                Toggle("Include workspace name", isOn: $settings.assistantIncludeWorkspace)
                Toggle("Include recent terminal output", isOn: $settings.assistantIncludeRecentOutput)
                Text("Only the fields switched on above are sent with a prompt, and full scrollback never is — only what is on screen, trimmed to the last 6,000 characters. Explain and Fix it ask first when this is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.assistantIncludeRecentOutput {
                    Text("Control sequences are stripped and values that look like API keys, tokens, passwords, private keys and URL credentials are masked before output is sent. That is best effort: a secret in a form it doesn't recognise — an env dump with an unusual name, say — still goes.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Error help") {
                Toggle("Offer Explain / Fix it after a command prints an error", isOn: $settings.assistantOfferErrorHelp)
                Text("When a command you run from the composer prints something that reads like an error, a row offers Explain and Fix it. Spotting it happens on this Mac, from the terminal's text; nothing is sent until you press one. From the offer, the command and only the new text that appeared after it are sent; from the Terminal menu, what is on screen and the command last sent from the composer if it is still there. If \"Include recent terminal output\" is off, you're asked each time and shown what would go. A suggested command is only ever put in the input for you to review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("""
                Prompts and the context toggles above go to the configured endpoint when you submit `@ai …` in the composer, and the command and output Explain / Fix it show go when you send them. Nothing is sent until an API key is saved (or the base URL is a localhost OpenAI-compatible server). Suggested commands are shown only — they can be put in the input to review and are never auto-executed.
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
        // Report what actually happened. Claiming "Key cleared." regardless of
        // the result left the Status row still reading "Key saved in keychain"
        // right below it, and the user believing a credential was revoked when
        // a locked keychain had refused.
        let deleted = KeychainStore.delete(OpenAICompatibleAssistant.apiKeyAccount)
        apiKeyDraft = ""
        keyMessage = deleted ? "Key cleared." : "Couldn't remove the key from your keychain."
    }
}
