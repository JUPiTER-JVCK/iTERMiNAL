import Foundation

/// Where an IP address's network and country can be looked up, and what comes
/// back. Foundation only: choosing the provider, building the question and
/// reading the answer live here; asking is `IPLookupModel`.
///
/// Every provider but `disabled` sends the address somewhere — IPinfo over
/// https, Team Cymru in a DNS query — so nothing is asked until one is chosen,
/// and only a public address is ever asked about.
enum GeoProvider: String, CaseIterable, Identifiable {
    case ipinfoLite
    case localMMDB
    case teamCymru
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ipinfoLite: return "IPinfo Lite"
        case .localMMDB: return "Local MMDB"
        case .teamCymru: return "DNS (Team Cymru)"
        case .disabled: return "Disabled"
        }
    }

    var detail: String {
        switch self {
        case .ipinfoLite: return "ASN, AS name, country, continent"
        case .localMMDB: return "Local ASN/country MMDB data"
        case .teamCymru: return "ASN, CIDR, country code"
        case .disabled: return "No third-party geo lookups"
        }
    }

    var explanation: String {
        switch self {
        case .ipinfoLite:
            return "Uses the IPinfo Lite API to look up ASN, organization name, country, and continent for IP addresses. IP addresses are sent to ipinfo.io over HTTPS. Needs a free IPinfo token, set in Settings → HTTP Client."
        case .localMMDB:
            return "Reads an MMDB database file on this Mac (IPinfo Lite, MaxMind GeoLite2, DB-IP). Nothing is sent anywhere. Choose the file in Settings → HTTP Client."
        case .teamCymru:
            return "Asks Team Cymru's IP-to-ASN DNS service for the ASN, network, and country code. The address is sent in a DNS query through this Mac's resolver."
        case .disabled:
            return "No address is sent anywhere. The Lookup tab shows only what this Mac's own resolver says."
        }
    }

    /// Whether this provider sends the address off the Mac.
    var leavesTheMac: Bool { self == .ipinfoLite || self == .teamCymru }
}

struct IPIntel: Equatable {
    var asn: String?
    var organisation: String?
    var domain: String?
    var network: String?
    var countryCode: String?
    var countryName: String?
    var continent: String?

    var isEmpty: Bool { self == IPIntel() }

    /// The country's flag, from its two-letter code.
    var flag: String? {
        guard let code = countryCode?.uppercased(), code.count == 2,
              code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        var flag = ""
        for scalar in code.unicodeScalars {
            if let regional = Unicode.Scalar(0x1F1E6 + scalar.value - 65) { flag.unicodeScalars.append(regional) }
        }
        return flag
    }

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    /// Label and value pairs in the order they are shown and copied.
    var rows: [Row] {
        var rows: [Row] = []
        if let asn { rows.append(Row(label: "ASN", value: asn)) }
        if let organisation { rows.append(Row(label: "Organization", value: organisation)) }
        if let domain { rows.append(Row(label: "Domain", value: domain)) }
        if let network { rows.append(Row(label: "Network", value: network)) }
        if let countryCode { rows.append(Row(label: "Country", value: countryCode)) }
        if let countryName { rows.append(Row(label: "Country Name", value: countryName)) }
        if let continent { rows.append(Row(label: "Continent", value: continent)) }
        return rows
    }

    /// Fills what can be worked out from the country code when the provider
    /// did not say: the country's name and its continent.
    mutating func fillFromCountryCode() {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return }
        countryCode = code
        if countryName == nil {
            countryName = IPIntelParse.countryName(code)
        }
        if continent == nil, let name = IPIntelParse.continentName(forCountry: code) {
            continent = name
        }
    }
}

enum IPIntelParse {
    static let maxResponseBytes = 64 * 1024

    // MARK: IPinfo Lite

    /// `{"ip":…, "asn":"AS15169", "as_name":…, "as_domain":…, "country_code":"US",
    /// "country":"United States", "continent_code":"NA", "continent":"North America"}`
    static func ipinfoLite(_ data: Data) -> Result<IPIntel, GeoLookup.Problem> {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return .failure(.unreadable) }
        if let status = dictionary["status"] as? Int, status >= 400 {
            let message = (dictionary["error"] as? [String: Any]).flatMap { clean($0["message"]) }
                ?? clean(dictionary["message"])
                ?? "The service refused the lookup."
            return .failure(.serviceSaid(message))
        }
        if let error = dictionary["error"] as? [String: Any] {
            return .failure(.serviceSaid(clean(error["message"]) ?? "The service refused the lookup."))
        }
        if let error = dictionary["error"] as? String, let message = clean(error) {
            return .failure(.serviceSaid(message))
        }
        var found = fromRecord(dictionary)
        found.fillFromCountryCode()
        guard !found.isEmpty else { return .failure(.unreadable) }
        return .success(found)
    }

    // MARK: MMDB records

    /// Reads a record from an MMDB file, whichever of the common layouts it
    /// has: IPinfo's flat fields, or MaxMind's and DB-IP's nested ones.
    static func fromRecord(_ record: [String: Any]) -> IPIntel {
        var found = IPIntel()
        if let asn = clean(record["asn"]) {
            found.asn = asn.uppercased().hasPrefix("AS") ? asn : "AS\(asn)"
        } else if let number = record["autonomous_system_number"] as? UInt64 {
            found.asn = "AS\(number)"
        }
        found.organisation = clean(record["as_name"]) ?? clean(record["autonomous_system_organization"]) ?? clean(record["org"])
        found.domain = clean(record["as_domain"])

        if let country = record["country"] as? [String: Any] {
            found.countryCode = clean(country["iso_code"])
            found.countryName = name(in: country)
        } else {
            found.countryCode = clean(record["country_code"])
            found.countryName = clean(record["country"])
        }
        if let continent = record["continent"] as? [String: Any] {
            found.continent = name(in: continent)
        } else {
            found.continent = clean(record["continent"])
        }
        if found.countryName == nil, let registered = record["registered_country"] as? [String: Any], found.countryCode == nil {
            found.countryCode = clean(registered["iso_code"])
        }
        found.fillFromCountryCode()
        return found
    }

    private static func name(in object: [String: Any]) -> String? {
        if let names = object["names"] as? [String: Any] { return clean(names["en"]) }
        return clean(object["name"])
    }

    // MARK: Team Cymru

    /// The DNS name that holds the origin of an address: `d.c.b.a.origin.asn.cymru.com`
    /// for IPv4, nibble-reversed under `origin6` for IPv6.
    static func cymruOriginName(for address: HostLookup.Address) -> String? {
        switch address.family {
        case .v4:
            var v4 = in_addr()
            guard inet_pton(AF_INET, address.text, &v4) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return bytes.reversed().map(String.init).joined(separator: ".") + ".origin.asn.cymru.com"
        case .v6:
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, address.text, &v6) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            let nibbles = bytes.flatMap { [String($0 >> 4, radix: 16), String($0 & 0xF, radix: 16)] }
            return nibbles.reversed().joined(separator: ".") + ".origin6.asn.cymru.com"
        }
    }

    static func cymruASNName(_ asn: String) -> String { "AS\(asn).asn.cymru.com" }

    /// `7018 | 23.121.0.0/16 | US | arin | 2008-04-01`. Returns the first ASN
    /// when several are listed.
    static func cymruOrigin(_ text: String) -> (asn: String, network: String?, country: String?)? {
        let fields = text.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3,
              let first = fields[0].split(separator: " ").first,
              first.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let network = fields[1].isEmpty ? nil : clean(fields[1])
        let country = fields[2].count == 2 ? fields[2].uppercased() : nil
        return (String(first), network, country)
    }

    /// `7018 | US | arin | 1999-04-12 | ATT-INTERNET4, US` — the name, without
    /// the country code Team Cymru appends to it.
    static func cymruASNName(fromText text: String) -> String? {
        let fields = text.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 5 else { return nil }
        var name = fields[4]
        if let comma = name.lastIndex(of: ","), name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces).count == 2 {
            name = String(name[..<comma])
        }
        return clean(name)
    }

    // MARK: Names

    static func countryName(_ code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    static func continentName(forCountry code: String) -> String? {
        continentByCountry[code.uppercased()]
    }

    private static let continentByCountry: [String: String] = {
        let groups: [(String, String)] = [
            ("Africa", "AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW"),
            ("Antarctica", "AQ BV GS HM TF"),
            ("Asia", "AE AF AM AZ BD BH BN BT CN CY GE HK ID IL IN IQ IR JO JP KG KH KP KR KW KZ LA LB LK MM MN MO MV MY NP OM PH PK PS QA SA SG SY TH TJ TL TM TR TW UZ VN YE"),
            ("Europe", "AD AL AT AX BA BE BG BY CH CZ DE DK EE ES FI FO FR GB GG GI GR HR HU IE IM IS IT JE LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM UA VA XK"),
            ("North America", "AG AI AW BB BL BM BQ BS BZ CA CR CU CW DM DO GD GL GP GT HN HT JM KN KY LC MF MQ MS MX NI PA PM PR SV SX TC TT US VC VG VI"),
            ("Oceania", "AS AU CK FJ FM GU KI MH MP NC NF NR NU NZ PF PG PN PW SB TK TO TV UM VU WF WS"),
            ("South America", "AR BO BR CL CO EC FK GF GY PE PY SR UY VE"),
        ]
        var table: [String: String] = [:]
        for (continent, codes) in groups {
            for code in codes.split(separator: " ") { table[String(code)] = continent }
        }
        return table
    }()

    // MARK: Text from outside

    /// A string from a service or a file, made safe to show: control
    /// characters out, and cut short.
    static func clean(_ value: Any?) -> String? {
        let string: String
        if let text = value as? String {
            string = text
        } else if let sub = value as? Substring {
            string = String(sub)
        } else {
            return nil
        }
        let printable = String(string.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    /// The address as it may sit in a URL path: hex digits, `.` and `:` stay,
    /// anything else is encoded.
    static func pathSafe(_ address: String) -> String? {
        let plain = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        return address.addingPercentEncoding(withAllowedCharacters: plain)
    }
}
