import SwiftUI
import AppKit

/// The HTTP client's Lookup tab: what this Mac's resolver says about a name or
/// an address, and — once a provider is chosen, and only for a public address —
/// the network and country that provider says it belongs to.
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
    /// What the chosen provider says about each address, by its text.
    @Published private(set) var intel: [String: IPIntel] = [:]
    @Published private(set) var locating: Set<String> = []
    @Published private(set) var locationProblems: [String: String] = [:]
    /// Answers kept this session so asking again does not send the address
    /// again. In memory only: nothing about an address is written to disk.
    @Published private(set) var cacheCount = 0

    /// Where the Keychain keeps the IPinfo token.
    static let ipinfoTokenAccount = "ipinfoToken"

    /// Set by the view from Settings, before each lookup.
    var config = IPLookupConfig()

    private var cache: [String: IPIntel] = [:]
    private var locateGeneration = 0

    private var generation = 0

    func lookUp() {
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isWorking else { return }
        isWorking = true
        message = nil
        entries = []
        intel = [:]
        locating = []
        locationProblems = [:]
        locateGeneration += 1
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
                // Entering an address is what asks the chosen provider about
                // it; with none chosen this does nothing.
                self.locateAll()
            }
        }
    }

    /// Asks the chosen provider about every address on screen, again — after
    /// the provider or its file changed.
    func refresh() {
        locateGeneration += 1
        intel = [:]
        locating = []
        locationProblems = [:]
        locateAll()
    }

    func clearCache() {
        cache = [:]
        cacheCount = 0
    }

    private func locateAll() {
        for entry in entries { locate(entry.address) }
    }

    private func cacheKey(_ config: IPLookupConfig, _ address: HostLookup.Address) -> String {
        let source: String
        switch config.provider {
        case .localMMDB: source = "\(config.mmdbPath)+\(config.asnMMDBPath)"
        case .rirDelegations: source = config.rirStamp
        default: source = ""
        }
        return "\(config.provider.rawValue)|\(source)|\(address.text)"
    }

    /// Asks the chosen provider about one public address. A private, local or
    /// reserved address is never sent anywhere.
    private func locate(_ address: HostLookup.Address) {
        let config = self.config
        guard config.provider != .disabled, GeoLookup.isQueryable(address) else { return }
        let key = cacheKey(config, address)
        if let hit = cache[key] {
            intel[address.text] = hit
            locationProblems[address.text] = nil
            return
        }
        guard !locating.contains(address.text) else { return }
        locating.insert(address.text)
        locationProblems[address.text] = nil
        let mine = locateGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.fetch(address, config: config)
            DispatchQueue.main.async {
                guard self.locateGeneration == mine else { return }
                self.locating.remove(address.text)
                switch result {
                case .success(let found):
                    self.intel[address.text] = found
                    self.cache[key] = found
                    self.cacheCount = self.cache.count
                case .failure(let problem):
                    self.locationProblems[address.text] = problem.message
                }
            }
        }
    }

    private struct Failure: Error { let message: String }

    private static func fetch(_ address: HostLookup.Address, config: IPLookupConfig) -> Result<IPIntel, Failure> {
        switch config.provider {
        case .ipinfoLite: return fetchIPinfo(address)
        case .localMMDB: return fetchMMDB(address, paths: [config.mmdbPath, config.asnMMDBPath])
        case .rirDelegations: return fetchRIR(address)
        case .teamCymru: return fetchCymru(address)
        case .disabled: return .failure(Failure(message: "Lookups are disabled."))
        }
    }

    private static func fetchIPinfo(_ address: HostLookup.Address) -> Result<IPIntel, Failure> {
        guard let token = KeychainStore.get(ipinfoTokenAccount), !token.isEmpty else {
            return .failure(Failure(message: "IPinfo Lite needs a token. Add one in Settings → HTTP Client."))
        }
        guard let path = IPIntelParse.pathSafe(address.text),
              let url = URL(string: "https://api.ipinfo.io/lite/\(path)") else {
            return .failure(Failure(message: "That address can't be sent to the service."))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("iTERMiNAL", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // As a header rather than in the URL, so the token is not in anything
        // that records URLs.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var body: Data?
        var status = 0
        var transportError: String?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            transportError = error?.localizedDescription
            done.signal()
        }.resume()
        done.wait()

        if let transportError { return .failure(Failure(message: transportError)) }
        guard let body, body.count <= IPIntelParse.maxResponseBytes else {
            return .failure(Failure(message: "The service's answer was missing or too large."))
        }
        switch IPIntelParse.ipinfoLite(body) {
        case .success(let found): return .success(found)
        case .failure(.serviceSaid(let said)): return .failure(Failure(message: said))
        case .failure(.unreadable):
            return .failure(Failure(message: status == 429
                ? "IPinfo says the request limit was reached."
                : "The service's answer couldn't be read (HTTP \(status))."))
        }
    }

    /// Reads each chosen file — a City database and an ASN one, say — and
    /// puts together what they say, the first file's answer first.
    private static func fetchMMDB(_ address: HostLookup.Address, paths: [String]) -> Result<IPIntel, Failure> {
        let chosen = paths.filter { !$0.isEmpty }
        guard !chosen.isEmpty else {
            return .failure(Failure(message: "Choose an MMDB file in Settings → HTTP Client."))
        }
        var found = IPIntel()
        var unreadable: [String] = []
        for path in chosen {
            guard let reader = MMDBReaderCache.reader(at: path) else {
                unreadable.append((path as NSString).lastPathComponent)
                continue
            }
            if let record = reader.lookup(address.text) {
                found = IPIntelParse.merged(found, with: IPIntelParse.fromRecord(record))
            }
        }
        if !found.isEmpty { return .success(found) }
        if !unreadable.isEmpty {
            return .failure(Failure(message: "\(unreadable.joined(separator: ", ")) isn't a readable MMDB database."))
        }
        return .failure(Failure(message: chosen.count == 1
            ? "The database has nothing for that address."
            : "Neither database has anything for that address."))
    }

    private static func fetchRIR(_ address: HostLookup.Address) -> Result<IPIntel, Failure> {
        let store = RIRDelegationStore.shared
        let table = store.table()
        guard !table.isEmpty else {
            return .failure(Failure(message: "Download the registries' files in Settings → HTTP Client."))
        }
        guard let delegation = table.lookup(address.text) else {
            return .failure(Failure(message: "No registry file on this Mac has a delegated block holding that address."))
        }
        return .success(IPIntelParse.fromDelegation(delegation))
    }

    private static func fetchCymru(_ address: HostLookup.Address) -> Result<IPIntel, Failure> {
        guard let name = IPIntelParse.cymruOriginName(for: address),
              let text = DNSTextQuery.txt(name),
              let origin = IPIntelParse.cymruOrigin(text) else {
            return .failure(Failure(message: "Team Cymru had no answer for that address."))
        }
        var found = IPIntel()
        found.asn = "AS\(origin.asn)"
        found.network = origin.network
        found.countryCode = origin.country
        if let nameText = DNSTextQuery.txt(IPIntelParse.cymruASNName(origin.asn)) {
            found.organisation = IPIntelParse.cymruASNName(fromText: nameText)
        }
        found.fillFromCountryCode()
        return .success(found)
    }
}

struct IPLookupConfig: Equatable {
    var provider: GeoProvider = .disabled
    var mmdbPath = ""
    /// A second MMDB file read alongside the first — GeoLite2 publishes its
    /// City and ASN data as separate files.
    var asnMMDBPath = ""
    /// Which download of the registries' files answers were read from.
    var rirStamp = ""
}

/// Keeps the open databases between lookups, so a large file is mapped once.
private enum MMDBReaderCache {
    private static let lock = NSLock()
    private static var readers: [String: MMDBReader?] = [:]

    static func reader(at path: String) -> MMDBReader? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = readers[path] { return cached }
        // Only the files in use now are kept: there are at most two.
        if readers.count >= 2 { readers = [:] }
        let reader = MMDBReader(url: URL(fileURLWithPath: path))
        readers[path] = reader
        return reader
    }
}

struct IPLookupView: View {
    @ObservedObject var model: IPLookupModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var rirFiles = RIRDelegationStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    private var currentConfig: IPLookupConfig {
        IPLookupConfig(provider: settings.ipLookupProvider,
                       mmdbPath: settings.ipLookupMMDBPath,
                       asnMMDBPath: settings.ipLookupASNMMDBPath,
                       rirStamp: rirFiles.stamp)
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Name or IP address", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit(lookUp)
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Look Up", action: lookUp)
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
                    providerPicker(theme: theme)
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
        .onAppear {
            model.config = currentConfig
            focused = true
        }
        .onChange(of: settings.ipLookupProviderTag) { _, _ in
            model.config = currentConfig
            model.refresh()
        }
        .onChange(of: settings.ipLookupMMDBPath) { _, _ in
            model.config = currentConfig
            if settings.ipLookupProvider == .localMMDB { model.refresh() }
        }
        .onChange(of: settings.ipLookupASNMMDBPath) { _, _ in
            model.config = currentConfig
            if settings.ipLookupProvider == .localMMDB { model.refresh() }
        }
        .onChange(of: rirFiles.stamp) { _, _ in
            model.config = currentConfig
            if settings.ipLookupProvider == .rirDelegations { model.refresh() }
        }
    }

    private func lookUp() {
        // The provider is read now, not when the tab appeared, so a change in
        // Settings applies to this lookup.
        model.config = currentConfig
        model.lookUp()
    }

    // MARK: Provider

    private func providerPicker(theme: Theme) -> some View {
        let chosen = settings.ipLookupProvider
        return VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(Array(GeoProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                    Button {
                        settings.ipLookupProvider = provider
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                Text(provider.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            if provider == chosen {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(settings.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < GeoProvider.allCases.count - 1 { FadedDivider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.textSecondary.opacity(0.08)))

            Text(chosen.explanation)
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if chosen != .disabled {
                HStack {
                    Button("Clear Geo Cache") { model.clearCache() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .disabled(model.cacheCount == 0)
                    Spacer(minLength: 0)
                    Text("\(model.cacheCount) \(model.cacheCount == 1 ? "entry" : "entries")")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    // MARK: Results

    private func entryView(_ entry: IPLookupModel.Entry, theme: Theme) -> some View {
        let address = entry.address
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(address.text)  ·  \(address.family.rawValue)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
            row("Kind", address.kind.label, theme: theme)
            row("Name", entry.reverseName ?? "No name found for it", theme: theme)

            if let found = model.intel[address.text] {
                ForEach(found.rows) { item in
                    if item.label == "Country", let flag = found.flag {
                        row(item.label, "\(item.value)  \(flag)", theme: theme)
                    } else {
                        row(item.label, item.value, theme: theme)
                    }
                }
                Button {
                    copy(address: address, found: found)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(settings.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if !GeoLookup.isQueryable(address) {
                Text("A private, local or reserved address: there is no network or country to look up, and it is never sent anywhere.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            } else if model.locating.contains(address.text) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(settings.ipLookupProvider.title)…")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            } else if settings.ipLookupProvider == .disabled {
                Text("Choose a provider above to look up this address's network and country.")
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

    private func copy(address: HostLookup.Address, found: IPIntel) {
        var lines = [address.text]
        lines += found.rows.map { "\($0.label): \($0.value)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
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
        Text("Names and address kinds come from this Mac's own resolver: the Name row is the address's reverse DNS (PTR) record, which its network's owner sets and need not match the name you typed. IPinfo Lite and Team Cymru are asked about a public address when you look it up, and are sent the address alone — not the name you typed. Local MMDB and RIR files never send it anywhere.")
            .font(.system(size: 10))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
