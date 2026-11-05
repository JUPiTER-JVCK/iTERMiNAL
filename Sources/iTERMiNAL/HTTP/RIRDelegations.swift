import Foundation

/// Country-level lookup from the Regional Internet Registries' own delegation
/// statistics — the `delegated-*-extended-latest` files ARIN, RIPE NCC, APNIC,
/// LACNIC and AFRINIC publish every day. Foundation only: reading the files and
/// searching them is checked off a Mac; downloading them is
/// `RIRDelegationStore`.
///
/// A line says which registry delegated a block of addresses, to a holder in
/// which country, and when:
///
///     ripencc|FR|ipv4|2.0.0.0|1048576|20100712|allocated|…
///     apnic|JP|ipv6|2001:200::|35|19990813|allocated|…
///
/// For IPv4 the fifth field is how many addresses the block holds, which need
/// not be a power of two; for IPv6 it is the prefix length. Only `allocated`
/// and `assigned` blocks are kept — `available` and `reserved` ones have no
/// holder, so no country.
///
/// The country is where the holder registered, which is not always where the
/// addresses are used: a block held by a multinational may be routed anywhere.
enum RIRRegistry: String, CaseIterable, Identifiable {
    case arin
    case ripencc
    case apnic
    case lacnic
    case afrinic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arin: return "ARIN"
        case .ripencc: return "RIPE NCC"
        case .apnic: return "APNIC"
        case .lacnic: return "LACNIC"
        case .afrinic: return "AFRINIC"
        }
    }

    /// The file's name, here and on the registry's server.
    var fileName: String { "delegated-\(rawValue)-extended-latest" }

    /// Where the registry publishes it. All five are https.
    var url: URL {
        switch self {
        case .arin: return URL(string: "https://ftp.arin.net/pub/stats/arin/\(fileName)")!
        case .ripencc: return URL(string: "https://ftp.ripe.net/pub/stats/ripencc/\(fileName)")!
        case .apnic: return URL(string: "https://ftp.apnic.net/stats/apnic/\(fileName)")!
        case .lacnic: return URL(string: "https://ftp.lacnic.net/pub/stats/lacnic/\(fileName)")!
        case .afrinic: return URL(string: "https://ftp.afrinic.net/pub/stats/afrinic/\(fileName)")!
        }
    }
}

/// What the registries say about one address.
struct RIRDelegation: Equatable {
    var registry: RIRRegistry
    var countryCode: String
    /// The delegated block: a CIDR when it is one, otherwise `first – last`.
    var network: String
    /// `yyyy-mm-dd`, when the file gave a date.
    var date: String?
    var status: String
}

/// Every delegated block from the files it was given, sorted by first address,
/// and searched by binary search.
struct RIRDelegationTable {
    fileprivate struct V6: Comparable {
        var high: UInt64
        var low: UInt64
        static func < (a: V6, b: V6) -> Bool { a.high != b.high ? a.high < b.high : a.low < b.low }
    }

    fileprivate struct Meta {
        var registry: UInt8
        var country: UInt16
        var date: UInt32
        var assigned: Bool
    }

    fileprivate struct Range4 {
        var first: UInt32
        var last: UInt32
        var meta: Meta
    }

    fileprivate struct Range6 {
        var first: V6
        var last: V6
        var prefix: UInt8
        var meta: Meta
    }

    private var v4: [Range4] = []
    private var v6: [Range6] = []

    var ipv4Count: Int { v4.count }
    var ipv6Count: Int { v6.count }
    var isEmpty: Bool { v4.isEmpty && v6.isEmpty }

    /// A file is the registry's, so it is treated like any download: a line
    /// that does not add up is skipped, never trusted.
    static let maxFileBytes = 64 * 1024 * 1024

    init() {}

    /// Builds the table from the files' contents, in any order.
    init(files: [Data]) {
        for file in files { add(file) }
        finish()
    }

    /// Adds one file's blocks. Call `finish()` once they are all in.
    mutating func add(_ file: Data) {
        guard file.count <= Self.maxFileBytes else { return }
        let bar = UInt8(ascii: "|")
        file.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let end = bytes.count
            while start < end {
                var stop = start
                while stop < end, bytes[stop] != 0x0A { stop += 1 }
                var lineEnd = stop
                if lineEnd > start, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd > start, bytes[start] != UInt8(ascii: "#") {
                    var fields: [Substring] = []
                    fields.reserveCapacity(8)
                    var fieldStart = start
                    for index in start...lineEnd {
                        if index == lineEnd || bytes[index] == bar {
                            fields.append(Substring(decoding: UnsafeBufferPointer(rebasing: bytes[fieldStart..<index]), as: UTF8.self))
                            fieldStart = index + 1
                            if fields.count == 8 { break }
                        }
                    }
                    addLine(fields)
                }
                start = stop + 1
            }
        }
    }

    /// Sorts what was added so it can be searched.
    mutating func finish() {
        v4.sort { $0.first != $1.first ? $0.first < $1.first : $0.last > $1.last }
        v6.sort { $0.first != $1.first ? $0.first < $1.first : $0.last > $1.last }
    }

    /// One `registry|cc|type|start|value|date|status` line. The version line,
    /// the summary lines and anything not delegated to a holder are skipped.
    private mutating func addLine(_ fields: [Substring]) {
        guard fields.count >= 7,
              let registry = RIRRegistry(rawValue: fields[0].lowercased()) else { return }
        let status = fields[6].lowercased()
        guard status == "allocated" || status == "assigned" else { return }
        guard let country = Self.countryKey(fields[1]) else { return }
        let meta = Meta(registry: UInt8(RIRRegistry.allCases.firstIndex(of: registry)!),
                        country: country,
                        date: Self.dateKey(fields[5]),
                        assigned: status == "assigned")
        switch fields[2] {
        case "ipv4":
            var address = in_addr()
            guard inet_pton(AF_INET, String(fields[3]), &address) == 1,
                  let count = UInt64(fields[4]), count >= 1 else { return }
            let first = UInt32(bigEndian: address.s_addr)
            let last = UInt64(first) + count - 1
            guard last <= UInt64(UInt32.max) else { return }
            v4.append(Range4(first: first, last: UInt32(last), meta: meta))
        case "ipv6":
            guard let first = Self.v6(String(fields[3])),
                  let prefix = UInt8(fields[4]), prefix <= 128 else { return }
            let (network, broadcast) = Self.bounds(first, prefix: Int(prefix))
            v6.append(Range6(first: network, last: broadcast, prefix: prefix, meta: meta))
        default:
            return
        }
    }

    // MARK: Search

    /// The block `address` falls in, or nil when no registry delegated one
    /// that holds it — or the text is not an address.
    func lookup(_ address: String) -> RIRDelegation? {
        let text = address.trimmingCharacters(in: .whitespaces)
        var v4Address = in_addr()
        if inet_pton(AF_INET, text, &v4Address) == 1 {
            return lookup4(UInt32(bigEndian: v4Address.s_addr))
        }
        guard let value = Self.v6(text) else { return nil }
        // An IPv4 address written as IPv6 (`::ffff:a.b.c.d`) is looked up as IPv4.
        if value.high == 0, value.low >> 32 == 0xFFFF {
            return lookup4(UInt32(truncatingIfNeeded: value.low))
        }
        return lookup6(value)
    }

    private func lookup4(_ value: UInt32) -> RIRDelegation? {
        guard let index = Self.lastIndex(in: v4, atOrBefore: value, key: \.first) else { return nil }
        // The registries do not delegate one block inside another, but a file
        // is not trusted to keep to that: a few blocks back are looked at too,
        // so a small block that starts later does not hide a larger one.
        var candidate = index
        for _ in 0..<8 {
            let range = v4[candidate]
            if range.first <= value, value <= range.last {
                return delegation(range.meta, network: Self.network4(range.first, range.last))
            }
            guard candidate > 0 else { break }
            candidate -= 1
        }
        return nil
    }

    private func lookup6(_ value: V6) -> RIRDelegation? {
        guard let index = Self.lastIndex(in: v6, atOrBefore: value, key: \.first) else { return nil }
        var candidate = index
        for _ in 0..<8 {
            let range = v6[candidate]
            if range.first <= value, value <= range.last {
                return delegation(range.meta, network: "\(Self.text6(range.first))/\(range.prefix)")
            }
            guard candidate > 0 else { break }
            candidate -= 1
        }
        return nil
    }

    /// The last index whose key is at or before `value`, by binary search.
    private static func lastIndex<Element, Key: Comparable>(in array: [Element], atOrBefore value: Key,
                                                            key: KeyPath<Element, Key>) -> Int? {
        var low = 0
        var high = array.count
        while low < high {
            let middle = (low + high) / 2
            if array[middle][keyPath: key] <= value { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    private func delegation(_ meta: Meta, network: String) -> RIRDelegation {
        let scalars = [UInt8(meta.country >> 8), UInt8(meta.country & 0xFF)]
        return RIRDelegation(registry: RIRRegistry.allCases[Int(meta.registry)],
                             countryCode: String(decoding: scalars, as: UTF8.self),
                             network: network,
                             date: Self.dateText(meta.date),
                             status: meta.assigned ? "assigned" : "allocated")
    }

    // MARK: Fields

    /// Two capital letters, packed. `ZZ` — unknown — and anything else is nil.
    private static func countryKey(_ field: Substring) -> UInt16? {
        let bytes = Array(field.utf8)
        guard bytes.count == 2,
              bytes.allSatisfy({ $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }),
              field != "ZZ" else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    /// `yyyymmdd` as a number, or 0 when there is no plausible date.
    private static func dateKey(_ field: Substring) -> UInt32 {
        guard field.utf8.count == 8, let value = UInt32(field), value >= 1980_01_01, value <= 2999_12_31 else { return 0 }
        return value
    }

    private static func dateText(_ key: UInt32) -> String? {
        guard key != 0 else { return nil }
        return String(format: "%04u-%02u-%02u", key / 10000, key / 100 % 100, key % 100)
    }

    // MARK: Addresses

    private static func v6(_ text: String) -> V6? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for index in 0..<8 { high = high << 8 | UInt64(bytes[index]) }
        for index in 8..<16 { low = low << 8 | UInt64(bytes[index]) }
        return V6(high: high, low: low)
    }

    private static func bounds(_ value: V6, prefix: Int) -> (V6, V6) {
        func mask(_ bits: Int) -> UInt64 { bits <= 0 ? 0 : bits >= 64 ? .max : ~(UInt64.max >> UInt64(bits)) }
        let highMask = mask(prefix)
        let lowMask = mask(prefix - 64)
        let first = V6(high: value.high & highMask, low: value.low & lowMask)
        let last = V6(high: first.high | ~highMask, low: first.low | ~lowMask)
        return (first, last)
    }

    private static func text6(_ value: V6) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { raw in
            for index in 0..<8 { raw[index] = UInt8(truncatingIfNeeded: value.high >> UInt64(56 - index * 8)) }
            for index in 0..<8 { raw[8 + index] = UInt8(truncatingIfNeeded: value.low >> UInt64(56 - index * 8)) }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        return String(cString: buffer)
    }

    private static func text4(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// A CIDR when the block is one — a power of two, aligned to its size —
    /// otherwise the first and last address.
    static func network4(_ first: UInt32, _ last: UInt32) -> String {
        let size = UInt64(last) - UInt64(first) + 1
        if size & (size - 1) == 0, UInt64(first) % size == 0 {
            let prefix = 32 - size.trailingZeroBitCount
            return "\(text4(first))/\(prefix)"
        }
        return "\(text4(first)) – \(text4(last))"
    }
}
