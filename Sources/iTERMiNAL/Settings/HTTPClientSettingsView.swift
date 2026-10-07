import SwiftUI

/// Settings → HTTP Client: timeout, redirects, the response-size cap the
/// request executor actually enforces, and what the site explorer may read.
/// Saved collections are a later milestone and have no settings here yet.
struct HTTPClientSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

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

            Section("Site explorer") {
                Toggle("Add links from pages I fetch to the map", isOn: $settings.httpRecordDiscoveredLinks)
                Text("The explorer (Explore, next to Request) maps a site from what the site itself publishes: its robots.txt, the sitemaps that file names, and the page you enter. With this on, links in any page you fetch are added too — read from the response already in hand, never fetched on their own. It does not guess at paths, probe for common directories, or follow anything off the site being mapped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Requests are sent only when you press Send or ⌘Return, or press Return on an explorer command — never as you type a URL. `open` in the explorer reads a site's robots.txt, the sitemaps it declares, and the page you entered; `get` fetches the one address you give it. A plain `http://` address is refused unless it points at this Mac; everything else goes out over HTTPS with ordinary system certificate trust, the same as the AI assistant's connection. Sent requests are kept as local history, with values that look like credentials masked (best effort, not a guarantee) before being written to disk, and are left out of exported snapshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
