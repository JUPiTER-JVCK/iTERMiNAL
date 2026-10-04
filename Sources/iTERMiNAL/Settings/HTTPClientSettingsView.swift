import SwiftUI

/// Settings → HTTP Client: timeout, redirects, and the response-size cap the
/// request executor actually enforces. Site Explorer and saved collections
/// are later milestones and have no settings here yet.
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

            Section("Privacy") {
                Text("Requests are sent only when you press Send or ⌘Return — never as you type a URL. A plain `http://` address is refused unless it points at this Mac; everything else goes out over HTTPS with ordinary system certificate trust, the same as the AI assistant's connection. Sent requests are kept as local history, redacted the same way terminal output is before being written to disk, and are left out of exported snapshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
