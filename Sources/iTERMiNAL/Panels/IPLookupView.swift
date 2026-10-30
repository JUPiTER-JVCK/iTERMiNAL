import SwiftUI
import AppKit

/// The HTTP client's Lookup tab: what this Mac's resolver says about a name or
/// an address, and — only if allowed in Settings → HTTP Client, and only for a
/// public address — where a location service says it is.
final class IPLookupModel: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let address: HostLookup.Address
        let reverseName: String?
    }

    @Published var query = ""
    @Published private(set) var isWorking = false
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var message: String?
    /// Location for one address, by its text.
    @Published private(set) var locations: [String: GeoLocation] = [:]
    @Published private(set) var locating: Set<String> = []
    @Published private(set) var locationProblems: [String: String] = [:]

    private var generation = 0

    func lookUp() {
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isWorking else { return }
        isWorking = true
        message = nil
        entries = []
        locations = [:]
        locationProblems = [:]
        generation += 1
        let mine = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let addresses: [HostLookup.Address]
            if let one = HostLookup.classify(asked) {
                addresses = [one]
            } else {
                addresses = HostLookup.resolve(asked)
            }
            let found = addresses.map { Entry(address: $0, reverseName: HostLookup.reverse($0.text)) }
            DispatchQueue.main.async {
                guard self.generation == mine else { return }
                self.entries = found
                self.isWorking = false
                if found.isEmpty { self.message = "“\(asked)” didn't resolve to an address." }
            }
        }
    }

    /// Asks the location service about one address. Called only from a button
    /// that is shown only when the setting allows it.
    func locate(_ address: HostLookup.Address, template: String) {
        guard !locating.contains(address.text) else { return }
        guard let url = GeoLookup.url(template: template, address: address) else {
            locationProblems[address.text] = "That address can't be sent to a location service, or the service address in Settings isn't a valid https one with {ip} in it."
            return
        }
        locating.insert(address.text)
        locationProblems[address.text] = nil
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("iTERMiNAL", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            var location: GeoLocation?
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let data, data.count <= GeoLookup.maxResponseBytes {
                switch GeoLookup.parse(data) {
                case .success(let found): location = found
                case .failure(.serviceSaid(let said)): failure = said
                case .failure(.unreadable): failure = "The service's answer couldn't be read."
                }
            } else {
                failure = "The service's answer was missing or too large."
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                self.locating.remove(address.text)
                if let location {
                    self.locations[address.text] = location
                } else {
                    self.locationProblems[address.text] = failure ?? "The lookup failed."
                }
            }
        }.resume()
    }
}

struct IPLookupView: View {
    @ObservedObject var model: IPLookupModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Name or IP address", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit(model.lookUp)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Look Up", action: model.lookUp)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .disabled(model.isWorking || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            FadedDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = model.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    ForEach(model.entries) { entry in
                        entryView(entry, theme: theme)
                    }
                    footer(theme: theme)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.background)
        .onAppear { focused = true }
    }

    private func entryView(_ entry: IPLookupModel.Entry, theme: Theme) -> some View {
        let address = entry.address
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(address.text)  ·  \(address.family.rawValue)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
            row("Kind", address.kind.label, theme: theme)
            row("Name", entry.reverseName ?? "No name found for it", theme: theme)

            if let location = model.locations[address.text] {
                if let place = location.place { row("Place", place, theme: theme) }
                if let coordinates = location.coordinates { row("Coordinates", coordinates, theme: theme) }
                if let zone = location.timezone { row("Time zone", zone, theme: theme) }
                if let organisation = location.organisation { row("Network", organisation, theme: theme) }
            } else if GeoLookup.isQueryable(address) {
                if settings.httpGeolocationEnabled {
                    HStack(spacing: 8) {
                        Button("Locate via \(GeoLookup.serviceHost(template: settings.httpGeolocationTemplate) ?? "the service")") {
                            model.locate(address, template: settings.httpGeolocationTemplate)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(settings.accentColor)
                        .disabled(model.locating.contains(address.text))
                        if model.locating.contains(address.text) {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    Text("Location lookups are off. They send this address to a third-party service, so they are turned on in Settings → HTTP Client.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                Text("A private, local or reserved address: there is no location to look up, and it is never sent anywhere.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            if let problem = model.locationProblems[address.text] {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String, theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func footer(theme: Theme) -> some View {
        Text("Names and address kinds come from this Mac's own resolver. Only a location lookup leaves the Mac, only when you press it, and it sends the address alone — not the name you typed.")
            .font(.system(size: 10))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
