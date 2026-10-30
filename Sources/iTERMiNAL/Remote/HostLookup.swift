import Foundation

/// Looking up a host or an address using this Mac's own resolver: the names an
/// address has, the addresses a name has, and what kind of address each is.
///
/// Nothing leaves the Mac except the ordinary DNS queries the system makes for
/// any lookup. There is no geolocation or reputation service behind it: asking
/// one would send the address someone is looking at to a third party, and this
/// app does not do that behind a button that says "look up".
enum HostLookup {
    enum Family: String, Equatable {
        case v4 = "IPv4"
        case v6 = "IPv6"
    }

    enum Kind: Equatable {
        case unspecified
        case loopback
        case privateNetwork
        case linkLocal
        case carrierGradeNAT
        case multicast
        case publicInternet

        var label: String {
            switch self {
            case .unspecified: return "Unspecified (any address)"
            case .loopback: return "Loopback — this machine"
            case .privateNetwork: return "Private network"
            case .linkLocal: return "Link-local"
            case .carrierGradeNAT: return "Shared address space (carrier-grade NAT)"
            case .multicast: return "Multicast"
            case .publicInternet: return "Public internet"
            }
        }

        /// Whether the address is one that is reachable from outside a local
        /// network at all.
        var isRoutableFromInternet: Bool { self == .publicInternet }
    }

    struct Address: Equatable, Identifiable {
        let text: String
        let family: Family
        let kind: Kind
        var id: String { text }
    }

    static let maxAddresses = 16
    static let maxQueryLength = 253

    // MARK: Classifying

    /// The address `text` spells, or nil when it is not an IP address.
    static func classify(_ text: String) -> Address? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            return Address(text: trimmed, family: .v4, kind: kind(ofIPv4: bytes))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return Address(text: trimmed, family: .v6, kind: kind(ofIPv6: bytes))
        }
        return nil
    }

    static func kind(ofIPv4 b: [UInt8]) -> Kind {
        guard b.count == 4 else { return .publicInternet }
        if b == [0, 0, 0, 0] { return .unspecified }
        if b[0] == 127 { return .loopback }
        if b[0] == 10 { return .privateNetwork }
        if b[0] == 172 && (16...31).contains(b[1]) { return .privateNetwork }
        if b[0] == 192 && b[1] == 168 { return .privateNetwork }
        if b[0] == 169 && b[1] == 254 { return .linkLocal }
        if b[0] == 100 && (64...127).contains(b[1]) { return .carrierGradeNAT }
        if (224...239).contains(b[0]) { return .multicast }
        return .publicInternet
    }

    static func kind(ofIPv6 b: [UInt8]) -> Kind {
        guard b.count == 16 else { return .publicInternet }
        if b.allSatisfy({ $0 == 0 }) { return .unspecified }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        if b[0] == 0xFF { return .multicast }
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return .linkLocal }
        if (b[0] & 0xFE) == 0xFC { return .privateNetwork }
        return .publicInternet
    }

    // MARK: Asking the resolver

    /// The addresses a name resolves to, at most `maxAddresses`. Blocks for as
    /// long as the system's resolver does, so it belongs off the main thread.
    static func resolve(_ name: String) -> [Address] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= maxQueryLength else { return [] }

        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType

        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(query, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }

        var seen = Set<String>()
        var found: [Address] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node, found.count < maxAddresses {
            if let address = current.pointee.ai_addr,
               let text = numericHost(address, length: current.pointee.ai_addrlen),
               !seen.contains(text),
               let classified = classify(text) {
                seen.insert(text)
                found.append(classified)
            }
            node = current.pointee.ai_next
        }
        return found
    }

    /// The name an address answers to, when it has one that the resolver knows.
    static func reverse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var buffer = [CChar](repeating: 0, count: 1025)

        var v4 = sockaddr_in()
        if inet_pton(AF_INET, trimmed, &v4.sin_addr) == 1 {
            v4.sin_family = sa_family_t(AF_INET)
            let status = withUnsafePointer(to: &v4) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
            return status == 0 ? String(cString: buffer) : nil
        }
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET6, trimmed, &v6.sin6_addr) == 1 {
            v6.sin6_family = sa_family_t(AF_INET6)
            let status = withUnsafePointer(to: &v6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                }
            }
            return status == 0 ? String(cString: buffer) : nil
        }
        return nil
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1025)
        let status = getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        return status == 0 ? String(cString: buffer) : nil
    }
}
