import Foundation

/// Where an IP address is, as a lookup service says. Foundation only: building
/// the request and reading the answer are checked off a Mac; making the request
/// is `IPLookupModel`.
///
/// This is the one feature in the app that sends an address to a third party,
/// so everything that decides whether and what to send is here, in one place:
/// only a *public* address ever leaves (a private or loopback one means nothing
/// to a service, and would say something about the network it is on), only the
/// address does (never the host name it was looked up from), and only over https.
struct GeoLocation: Equatable {
    var country: String?
    var region: String?
    var city: String?
    var timezone: String?
    var organisation: String?
    var latitude: Double?
    var longitude: Double?

    /// "City, Region, Country", whatever of it there is.
    var place: String? {
        let parts = [city, region, country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var coordinates: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }
}

enum GeoLookup {
    /// `{ip}` is where the address goes. ipwho.is takes the address in the path,
    /// needs no key, and answers over https; any service that does the same can
    /// be put in its place in Settings.
    static let defaultTemplate = "https://ipwho.is/{ip}"
    static let placeholder = "{ip}"
    static let maxResponseBytes = 64 * 1024

    enum Problem: Error, Equatable {
        /// The service answered, and said no.
        case serviceSaid(String)
        case unreadable
    }

    // MARK: What may be sent

    /// Whether an address is one a location service can say anything about.
    static func isQueryable(_ address: HostLookup.Address) -> Bool {
        address.kind.isRoutableFromInternet
    }

    /// The URL to ask, or nil when it should not be asked at all: a template
    /// that is not https, or that does not hold `{ip}` exactly once, or whose
    /// result is not a URL with a host — and an address that is not public.
    static func url(template: String, address: HostLookup.Address) -> URL? {
        guard isQueryable(address) else { return nil }
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("https://"),
              trimmed.components(separatedBy: placeholder).count == 2 else { return nil }
        // The address is digits, hex and `.` or `:` — `HostLookup.classify` only
        // accepts what `inet_pton` does — but it is encoded all the same, so
        // nothing about the address can change the URL's shape.
        guard let encoded = address.text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let built = trimmed.replacingOccurrences(of: placeholder, with: encoded)
        guard let url = URL(string: built), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The service's host, for a button that says who will be asked.
    static func serviceHost(template: String) -> String? {
        let probe = template.replacingOccurrences(of: placeholder, with: "8.8.8.8")
        return URL(string: probe.trimmingCharacters(in: .whitespaces))?.host
    }

    // MARK: Reading the answer

    /// Reads the shapes the common free services answer in — ipwho.is,
    /// ipapi.co, ipinfo.io — by the names each uses for the same things. A field
    /// a service lacks is left empty, not guessed.
    static func parse(_ data: Data) -> Result<GeoLocation, Problem> {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return .failure(.unreadable) }

        if let success = dictionary["success"] as? Bool, !success {
            return .failure(.serviceSaid(text(dictionary["message"]) ?? "The service refused the lookup."))
        }
        if let failed = dictionary["error"] as? Bool, failed {
            return .failure(.serviceSaid(text(dictionary["reason"]) ?? text(dictionary["message"]) ?? "The service refused the lookup."))
        }

        var found = GeoLocation()
        found.country = text(dictionary["country_name"]) ?? text(dictionary["country"])
        found.region = text(dictionary["region"]) ?? text(dictionary["region_name"])
        found.city = text(dictionary["city"])

        if let zone = dictionary["timezone"] as? [String: Any] {
            found.timezone = text(zone["id"])
        } else {
            found.timezone = text(dictionary["timezone"])
        }

        found.organisation = text(dictionary["org"]) ?? text(dictionary["isp"])
        if found.organisation == nil, let connection = dictionary["connection"] as? [String: Any] {
            found.organisation = text(connection["org"]) ?? text(connection["isp"])
        }

        found.latitude = number(dictionary["latitude"]) ?? number(dictionary["lat"])
        found.longitude = number(dictionary["longitude"]) ?? number(dictionary["lon"]) ?? number(dictionary["lng"])
        if found.latitude == nil, let loc = dictionary["loc"] as? String {
            let pair = loc.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if pair.count == 2, let lat = pair[0], let lon = pair[1] {
                found.latitude = lat
                found.longitude = lon
            }
        }
        if let lat = found.latitude, !(-90...90).contains(lat) { found.latitude = nil; found.longitude = nil }
        if let lon = found.longitude, !(-180...180).contains(lon) { found.latitude = nil; found.longitude = nil }

        guard found != GeoLocation() else { return .failure(.unreadable) }
        return .success(found)
    }

    /// A string from the service, made safe to show: control characters out,
    /// and cut short, since it is text from outside.
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let printable = String(string.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double, double.isFinite { return double }
        if let string = value as? String, let double = Double(string), double.isFinite { return double }
        return nil
    }
}
