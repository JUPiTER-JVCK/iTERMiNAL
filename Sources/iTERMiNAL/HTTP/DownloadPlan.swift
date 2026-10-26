import Foundation

/// What a page is allowed to make this app fetch.
///
/// Saving the images or files a page lists means requesting addresses *the page
/// chose*. A page is free to list an address that is not on the internet at all
/// — a device on the local network, a service on this Mac, a cloud provider's
/// metadata address — and a browser will happily ask for it. This app will not:
/// a page that came from the internet cannot send a request to this Mac or the
/// network it is on. A page that is itself local (a dev server being looked at)
/// may reference local things.
///
/// Names are judged as written. A public name that points at a private address
/// is not caught here; that needs the address looked up, which this does not do.
enum DownloadPolicy {
    /// Why `address`, named by the page at `pageURL`, may not be fetched; nil
    /// if it may.
    static func refusal(for address: String, from pageURL: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return "not an address" }
        guard scheme == "http" || scheme == "https" else { return "only http and https addresses are fetched" }
        guard let host = url.host, !host.isEmpty else { return "no host in the address" }

        let pageHost = URL(string: pageURL)?.host ?? ""
        let pageIsLocal = isLocalHost(pageHost)
        if scheme == "http" {
            // The same rule as the HTTP client: plain http only to this Mac.
            guard AssistantDestination.isLoopback(host: host) else {
                return "plain http is only used for this Mac itself, and \(host) would need https"
            }
        }
        if isLocalHost(host), !pageIsLocal {
            return "a page from \(pageHost.isEmpty ? "the internet" : pageHost) can't make this app fetch from \(host), which is on this Mac or its network"
        }
        return nil
    }

    /// Whether a host is this Mac, or on a network that is not the internet:
    /// loopback, private, link-local and unspecified addresses, and names that
    /// only mean something locally.
    static func isLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return false }

        if host.contains(":") { return isLocalIPv6(host) }

        // Anything made only of digits, dots and hex is an address in some
        // spelling — `127.1`, `2130706433`, `0x7f000001`, `0177.0.0.1` — and a
        // browser reads them all. Only the plain dotted form is judged by its
        // octets; every other spelling is refused as suspicious.
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" || ("a"..."f").contains($0) }), host.contains(where: \.isNumber) {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let octets = parts.compactMap { part -> Int? in
                guard part.allSatisfy(\.isNumber), part.count <= 3, part.first != "0" || part.count == 1 else { return nil }
                return Int(part)
            }
            guard parts.count == 4, octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return true }
            return isLocalIPv4(octets)
        }

        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".localdomain", ".intranet", ".corp"] where host.hasSuffix(suffix) {
            return true
        }
        // A name with no dot is a machine on the local network.
        return !host.contains(".")
    }

    private static func isLocalIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true   // carrier-grade NAT
        default: return false
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host   // a zone id
        if address == "::" || address == "::1" { return true }
        if address.hasPrefix("fe8") || address.hasPrefix("fe9") || address.hasPrefix("fea") || address.hasPrefix("feb") { return true }
        if address.hasPrefix("fc") || address.hasPrefix("fd") { return true }
        // `::ffff:127.0.0.1` is IPv4 in IPv6 clothes.
        if address.hasPrefix("::ffff:") {
            let tail = String(address.dropFirst("::ffff:".count))
            return tail.contains(".") ? isLocalHost(tail) : true
        }
        return false
    }
}

/// One file to fetch, and what to call it.
struct DownloadItem: Equatable, Identifiable {
    let url: String
    let fileName: String
    var id: String { url }
}

/// A batch of downloads, sorted into what will be fetched and what will not,
/// with the reason for each that will not.
struct DownloadPlan: Equatable {
    struct Refusal: Equatable {
        let url: String
        let reason: String
    }

    /// A batch is capped: hundreds of requests to someone else's server is not
    /// what "save these" means.
    static let maxItems = 500

    var items: [DownloadItem] = []
    var refused: [Refusal] = []
    /// Addresses past `maxItems`, which were left out.
    var overLimit = 0

    /// The distinct hosts the items come from, most files first — what a person
    /// is shown before agreeing to fetch from them.
    var hosts: [String] {
        let counts = Dictionary(grouping: items.compactMap { URL(string: $0.url)?.host?.lowercased() }, by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// `taken` is names already in the folder, so a new file never replaces one.
    static func make(urls: [String], pageURL: String, taken: Set<String> = []) -> DownloadPlan {
        var plan = DownloadPlan()
        var used = Set(taken.map { $0.lowercased() })
        var seen = Set<String>()
        for address in urls {
            guard seen.insert(address).inserted else { continue }
            if let reason = DownloadPolicy.refusal(for: address, from: pageURL) {
                plan.refused.append(Refusal(url: address, reason: reason))
                continue
            }
            guard plan.items.count < maxItems else {
                plan.overLimit += 1
                continue
            }
            // Compared in lower case: the usual Mac disk does not tell
            // `Photo.PNG` from `photo.png`.
            let name = AssetNaming.unique(AssetNaming.fileName(for: address)) { used.contains($0.lowercased()) }
            used.insert(name.lowercased())
            plan.items.append(DownloadItem(url: address, fileName: name))
        }
        return plan
    }
}
