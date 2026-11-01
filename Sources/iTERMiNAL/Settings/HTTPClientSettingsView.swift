import SwiftUI
import AppKit

/// Settings → HTTP Client: timeout, redirects, the response-size cap the
/// request executor actually enforces, and what the site explorer may read.
/// Saved collections are a later milestone and have no settings here yet.
struct HTTPClientSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var ipinfoToken = ""
    @State private var hasSavedToken = KeychainStore.get(IPLookupModel.ipinfoTokenAccount) != nil

    private func saveIPinfoToken() {
        let trimmed = ipinfoToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, for: IPLookupModel.ipinfoTokenAccount) {
            ipinfoToken = ""
            hasSavedToken = true
        }
    }

    private func removeIPinfoToken() {
        _ = KeychainStore.delete(IPLookupModel.ipinfoTokenAccount)
        hasSavedToken = KeychainStore.get(IPLookupModel.ipinfoTokenAccount) != nil
    }

    private func chooseMMDB() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an .mmdb database (IPinfo Lite, GeoLite2, DB-IP)."
        if panel.runModal() == .OK, let url = panel.url {
            settings.ipLookupMMDBPath = url.path
        }
    }

    var body: some View {
        Form {
            Section("Requests") {
                HStack {
                    Text("Timeout")
                    Slider(value: $settings.httpRequestTimeout, in: 5...120, step: 5)
                    Text("\(Int(settings.httpRequestTimeout))s")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                Toggle("Follow redirects", isOn: $settings.httpFollowRedirects)

                Picker("Max response size", selection: $settings.httpMaxResponseBytes) {
                    Text("1 MB").tag(1_000_000)
                    Text("10 MB").tag(10_000_000)
                    Text("50 MB").tag(50_000_000)
                }

                Text("A response is cut off the moment it passes this size, before the rest is downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("IP lookup") {
                Picker("Look addresses up with", selection: $settings.ipLookupProviderTag) {
                    ForEach(GeoProvider.allCases) { provider in
                        Text(provider.title).tag(provider.rawValue)
                    }
                }
                Text(settings.ipLookupProvider.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("IPinfo token", text: $ipinfoToken)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Save") { saveIPinfoToken() }
                        .disabled(ipinfoToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasSavedToken {
                        Button("Remove") { removeIPinfoToken() }
                    }
                }
                Text(hasSavedToken
                     ? "A token is saved in the Keychain. It is sent to ipinfo.io only, as the lookup's credential."
                     : "A free token from ipinfo.io is needed for IPinfo Lite. It is kept in the Keychain, never in preferences or an exported snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("MMDB file")
                    Spacer()
                    Text(settings.ipLookupMMDBPath.isEmpty
                         ? "None chosen"
                         : (settings.ipLookupMMDBPath as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { chooseMMDB() }
                    if !settings.ipLookupMMDBPath.isEmpty {
                        Button("Clear") { settings.ipLookupMMDBPath = "" }
                    }
                }
                Text("Only a public address is ever looked up; private, local and reserved ones are never sent anywhere. The Lookup tab always shows what this Mac's own resolver says.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Site explorer") {
                Toggle("Add links from pages I fetch to the map", isOn: $settings.httpRecordDiscoveredLinks)
                Text("The explorer (Explore, next to Request) maps a site from what the site itself publishes: its robots.txt, the sitemaps that file names, and the page you enter. With this on, links in any page you fetch are added too — read from the response already in hand, never fetched on their own. It does not guess at paths, probe for common directories, or follow anything off the site being mapped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Downloads") {
                HStack {
                    Text("Save to")
                    Spacer()
                    Text((PageExtractionModel.defaultDownloadFolder(preferred: settings.httpDownloadFolder).path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…") { chooseFolder() }
                    if !settings.httpDownloadFolder.isEmpty {
                        Button("Reset") { settings.httpDownloadFolder = "" }
                    }
                }

                Picker("Largest file", selection: $settings.httpMaxDownloadMB) {
                    Text("25 MB").tag(25)
                    Text("100 MB").tag(100)
                    Text("250 MB").tag(250)
                    Text("1 GB").tag(1000)
                }

                Toggle("Show image previews in Extract", isOn: $settings.httpImagePreviews)
                Text("Previews put a small picture beside each address in the Images list. Each is a request to the site that hosts the image, made as you scroll to its row — at most \(ImagePreviewPolicy.perResponse) for a page, a few at a time, and none larger than \(ImagePreviewPolicy.maxBytes / 1_000_000) MB. They follow the same rules as downloads below, and are decoded by the system's image code, so they start off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Extract → Download saves the images, video, audio and files a page names — only the ones you pick, after showing you which sites and which folder. Files go in a folder per site, never over one that is there, marked as downloaded from the web so macOS asks before opening anything that could run. Requests carry no cookies, no credentials and none of the headers the page was fetched with, and a redirect to somewhere this app would not go is refused. A page from the internet cannot make this app fetch from this Mac or its network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Requests are sent only when you press Send or ⌘Return, press Return on an explorer command, or choose Fetch on a row of the Extract tab — never as you type a URL. `open` in the explorer reads a site's robots.txt, the sitemaps it declares, and the page you entered; `get` fetches the one address you give it. Extract reads only the response you already have. It asks for more only when you tell it to: a file when you press Download on a list you were shown, a small picture per row if you turned Previews on, the pages of a crawl you started from its sheet (one at a time, after reading the site's robots.txt), and, from Ask…, the AI assistant you set up in Settings → AI, which gets the page's text after a sheet that shows what and where. A plain `http://` address is refused unless it points at this Mac; everything else goes out over HTTPS with ordinary system certificate trust, the same as the AI assistant's connection. Sent requests are kept as local history, with values that look like credentials masked (best effort, not a guarantee) before being written to disk, and are left out of exported snapshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = PageExtractionModel.defaultDownloadFolder(preferred: settings.httpDownloadFolder)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { settings.httpDownloadFolder = url.path }
    }
}
