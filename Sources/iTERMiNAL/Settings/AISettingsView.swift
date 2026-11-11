import SwiftUI

/// Settings → AI: OpenAI-compatible endpoint, model, keychain-backed API key,
/// and which bits of terminal context travel with a prompt.
struct AISettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var apiKeyDraft = ""
    @State private var keyMessage: String?
    @State private var providerPreset: AssistantProvider = .openai
    @State private var localModels: [String] = []
    @State private var localModelsNote: String?
    @State private var loadingModels = false

    var body: some View {
        Form {
            Section("Provider") {
                // The setter, not an onChange, does the work: only a pick made
                // here rewrites the address and model. Syncing the picker to a
                // URL that was loaded or edited must not touch either.
                Picker("Preset", selection: Binding(
                    get: { providerPreset },
                    set: { choose($0) }
                )) {
                    ForEach(AssistantProvider.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }

                TextField("Base URL", text: $settings.assistantBaseURL)
                    .disabled(providerPreset != .custom && providerPreset.baseURL != nil)
                    .onChange(of: settings.assistantBaseURL) { _, newValue in
                        // Keep the preset in sync when the URL was edited
                        // elsewhere or loaded from preferences.
                        providerPreset = AssistantProvider.matching(baseURL: newValue)
                    }

                TextField("Model", text: $settings.assistantModel)

                // Only a server on this Mac is asked, for its list and nothing else.
                if let listURL = LocalModels.listURL(baseURL: settings.assistantBaseURL) {
                    HStack {
                        Button("List Models") { fetchLocalModels(listURL) }
                            .disabled(loadingModels)
                        if !localModels.isEmpty {
                            Menu("Choose…") {
                                ForEach(localModels, id: \.self) { name in
                                    Button(name) { settings.assistantModel = name }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if let localModelsNote {
                        Text(localModelsNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("OpenAI-compatible chat completions at `{base}/chat/completions`. Point the base URL at Ollama or any compatible proxy for local models.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if providerPreset == .claude {
                    Text("Claude is reached through Anthropic's OpenAI-compatible endpoint, with an API key from the Claude Console — a Claude.ai account login is not used. Anthropic describes that endpoint as meant for testing and comparison rather than long-term use.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let keysPage = providerPreset.keysPage {
                        Link("Get an API key in the Claude Console", destination: keysPage)
                            .font(.caption)
                    }
                }
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
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(keyHelp)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Context") {
                Toggle("Include working directory", isOn: $settings.assistantIncludeCwd)
                Toggle("Include git branch", isOn: $settings.assistantIncludeGitBranch)
                Toggle("Include space name", isOn: $settings.assistantIncludeWorkspace)
                Toggle("Include recent terminal output", isOn: $settings.assistantIncludeRecentOutput)
                Text("Only the fields switched on above are sent with a prompt, and full scrollback never is — only what is on screen, trimmed to the last 6,000 characters. Explain and Fix it ask first when this is off.")
                    .font(.subheadline)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Asking about a web page") {
                Text("In the HTTP client's Extract tab, Ask… sends the text of the page you have in hand, its address and title, and what you asked for, to the same endpoint — after a sheet that says where it goes and can show every character. Keys and passwords are masked first (best effort, and nothing else is, so don't send a private page), the text is cut at 12,000 characters, and the answer comes back as a table of text that is only ever shown: nothing in it is run, opened or fetched.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("In the Cheatsheet, Ask AI sends what you typed in its search field and the 40 commands the cheatsheet found closest, one line each, to the same endpoint — after a sheet that says where it goes and can show every character. Keys and passwords in what you typed are masked first, nothing from your terminal is included, and the assistant is asked to choose among those commands, not to write one: its answer is only ever shown, and nothing in it is run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("""
                Prompts and the context toggles above go to the configured endpoint when you submit `@ai …` in the composer, and the command and output Explain / Fix it show go when you send them, and a web page's text goes when you press Ask on the sheet in Extract, and the Cheatsheet's question and closest commands go when you press Ask on its sheet. Nothing is sent until an API key is saved (or the base URL is a localhost OpenAI-compatible server). Suggested commands are shown only — they can be put in the input to review and are never auto-executed.
                """)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            providerPreset = AssistantProvider.matching(baseURL: settings.assistantBaseURL)
        }
    }

    /// Asks the server on this Mac what models it has. No key is sent, a
    /// redirect to anywhere else is refused, and the answer is only names.
    private func fetchLocalModels(_ url: URL) {
        loadingModels = true
        localModelsNote = nil
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession(configuration: .ephemeral)
                    .data(for: request, delegate: NoRedirects())
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let names = status == 200 ? LocalModels.parse(data) : []
                await MainActor.run {
                    localModels = names
                    localModelsNote = status != 200
                        ? "The server answered \(status), not a list."
                        : names.isEmpty ? "The server listed no models." : "\(names.count) model\(names.count == 1 ? "" : "s") on this Mac."
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    localModels = []
                    localModelsNote = "Couldn't reach a server at \(url.host ?? "this Mac"): is it running?"
                    loadingModels = false
                }
            }
        }
    }

    /// A pick from the preset menu: the address it fixes, and a model that
    /// provider accepts when the field still holds another provider's stock one.
    private func choose(_ provider: AssistantProvider) {
        providerPreset = provider
        // A key typed for the provider just left must not be saved under the
        // one just chosen, and its "saved"/"cleared" note is no longer true.
        apiKeyDraft = ""
        keyMessage = nil
        if let url = provider.baseURL {
            settings.assistantBaseURL = url
        }
        if let model = provider.model(afterSwitchingFrom: settings.assistantModel) {
            settings.assistantModel = model
        }
    }

    /// The keychain item for the address in use: Claude's has its own, so a key
    /// saved for another provider is neither shown as set here nor sent there.
    private var keyAccount: String {
        AssistantDestination.keyAccount(forBaseURL: settings.assistantBaseURL)
    }

    /// Built as a `String` first so the account name inside the backticks is
    /// still read as Markdown code.
    private var keyHelp: LocalizedStringKey {
        let text = "The key is write-only: it lives in the keychain under `\(keyAccount)` and is never stored in preferences or export snapshots."
        return LocalizedStringKey(text)
    }

    private var hasSavedKey: Bool {
        let key = KeychainStore.get(keyAccount) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, for: keyAccount) {
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
        let deleted = KeychainStore.delete(keyAccount)
        apiKeyDraft = ""
        keyMessage = deleted ? "Key cleared." : "Couldn't remove the key from your keychain."
    }
}

/// Refuses every redirect: the list is asked of this Mac and nowhere else.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
