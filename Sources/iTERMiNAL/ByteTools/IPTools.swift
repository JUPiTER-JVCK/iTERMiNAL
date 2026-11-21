import Foundation

/// An IPv4 or IPv6 address as bytes, with every way it is written and what
/// kind of address it is.
struct IPAddressInfo: Equatable {
    /// Four bytes, or sixteen.
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    var isV4: Bool { bytes.count == 4 }
    var version: Int { isV4 ? 4 : 6 }

    /// `192.168.1.1`, or for IPv6 the shortest form (RFC 5952).
    var text: String { isV4 ? dotted : compressed }

    var dotted: String { bytes.map { String($0) }.joined(separator: ".") }

    /// IPv6 as eight four-digit groups, nothing left out.
    var expanded: String {
        groups.map { group in
            let digits = String(group, radix: 16)
            return String(repeating: "0", count: 4 - digits.count) + digits
        }.joined(separator: ":")
    }

    /// IPv6 in its shortest written form: lower case, no leading zeros, the
    /// longest run of zero groups (two or more) as `::`.
    var compressed: String {
        let g = groups
        var bestStart = -1
        var bestLength = 0
        var index = 0
        while index < g.count {
            if g[index] == 0 {
                var end = index
                while end < g.count, g[end] == 0 { end += 1 }
                if end - index > bestLength {
                    bestStart = index
                    bestLength = end - index
                }
                index = end
            } else {
                index += 1
            }
        }
        func join(_ slice: ArraySlice<UInt16>) -> String { slice.map { String($0, radix: 16) }.joined(separator: ":") }
        guard bestLength >= 2 else { return join(g[...]) }
        return join(g[0..<bestStart]) + "::" + join(g[(bestStart + bestLength)...])
    }

    /// 16-bit groups of an IPv6 address (eight), or of an IPv4 one (two).
    var groups: [UInt16] {
        stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    }

    var integer: String { BigNumber(bytes: bytes).toString(base: 10) }

    var hex: String { "0x" + ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: "", prefix: "", uppercase: true)) }

    /// The bits, in groups of eight for IPv4 (`11000000.10101000…`) and of sixteen for IPv6.
    var binary: String {
        if isV4 { return bytes.map { ByteFormat.binary.encode([$0]) }.joined(separator: ".") }
        return groups.map { group in
            let digits = String(group, radix: 2)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }.joined(separator: " ")
    }

    /// The name a reverse (PTR) lookup asks for.
    var reverseName: String {
        if isV4 { return bytes.reversed().map { String($0) }.joined(separator: ".") + ".in-addr.arpa" }
        let nibbles = bytes.flatMap { [String($0 >> 4, radix: 16), String($0 & 15, radix: 16)] }
        return nibbles.reversed().joined(separator: ".") + ".ip6.arpa"
    }

    /// IPv4 inside IPv6 (`::ffff:1.2.3.4`), written both ways, when it is one.
    var mappedIPv4: IPAddressInfo? {
        guard !isV4, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        return IPAddressInfo(bytes: Array(bytes[12...]))
    }

    /// The IPv4 address written as IPv4-mapped IPv6.
    var asMappedIPv6: String? {
        guard isV4 else { return nil }
        return "::ffff:" + dotted
    }

    // MARK: What kind

    private struct Block {
        let prefix: [UInt8]
        let length: Int
        let name: String
    }

    private static let v4Blocks: [Block] = [
        Block(prefix: [0], length: 8, name: "“this network” (0.0.0.0/8)"),
        Block(prefix: [10], length: 8, name: "private (10.0.0.0/8)"),
        Block(prefix: [100, 64], length: 10, name: "shared address space, carrier-grade NAT (100.64.0.0/10)"),
        Block(prefix: [127], length: 8, name: "loopback (127.0.0.0/8)"),
        Block(prefix: [169, 254], length: 16, name: "link-local (169.254.0.0/16)"),
        Block(prefix: [172, 16], length: 12, name: "private (172.16.0.0/12)"),
        Block(prefix: [192, 0, 0], length: 24, name: "IETF protocol assignments (192.0.0.0/24)"),
        Block(prefix: [192, 0, 2], length: 24, name: "documentation, TEST-NET-1 (192.0.2.0/24)"),
        Block(prefix: [192, 168], length: 16, name: "private (192.168.0.0/16)"),
        Block(prefix: [198, 18], length: 15, name: "benchmarking (198.18.0.0/15)"),
        Block(prefix: [198, 51, 100], length: 24, name: "documentation, TEST-NET-2 (198.51.100.0/24)"),
        Block(prefix: [203, 0, 113], length: 24, name: "documentation, TEST-NET-3 (203.0.113.0/24)"),
        Block(prefix: [224], length: 4, name: "multicast (224.0.0.0/4)"),
        Block(prefix: [240], length: 4, name: "reserved for future use (240.0.0.0/4)"),
    ]

    private static let v6Blocks: [Block] = [
        Block(prefix: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF], length: 96, name: "IPv4-mapped (::ffff:0:0/96)"),
        Block(prefix: [0, 0x64, 0xFF, 0x9B], length: 96, name: "NAT64 translation (64:ff9b::/96)"),
        Block(prefix: [0x20, 0x01, 0x0D, 0xB8], length: 32, name: "documentation (2001:db8::/32)"),
        Block(prefix: [0xFE, 0x80], length: 10, name: "link-local (fe80::/10)"),
        Block(prefix: [0xFC], length: 7, name: "unique local, the private range (fc00::/7)"),
        Block(prefix: [0xFF], length: 8, name: "multicast (ff00::/8)"),
        Block(prefix: [0x20], length: 3, name: "global unicast (2000::/3)"),
    ]

    /// What the address is for, in words: private, loopback, documentation…
    var kind: String {
        if isV4, bytes == [255, 255, 255, 255] { return "limited broadcast (255.255.255.255)" }
        if isV4, bytes == [0, 0, 0, 0] { return "unspecified (0.0.0.0)" }
        if !isV4, bytes.allSatisfy({ $0 == 0 }) { return "unspecified (::)" }
        if !isV4, bytes == [UInt8](repeating: 0, count: 15) + [1] { return "loopback (::1)" }
        for block in isV4 ? IPAddressInfo.v4Blocks : IPAddressInfo.v6Blocks where IPAddressInfo.matches(bytes, block.prefix, block.length) {
            return block.name
        }
        return isV4 ? "public (globally routable)" : "reserved or unassigned"
    }

    fileprivate static func matches(_ bytes: [UInt8], _ prefix: [UInt8], _ length: Int) -> Bool {
        for bit in 0..<length {
            let byteIndex = bit / 8
            let mask = UInt8(0x80) >> UInt8(bit % 8)
            let expected = byteIndex < prefix.count ? prefix[byteIndex] : 0
            if bytes[byteIndex] & mask != expected & mask { return false }
        }
        return true
    }
}

enum IPTools {
    // MARK: Reading

    /// An address in any of the forms people write: dotted IPv4, an IPv6 address
    /// (full, `::`-shortened, with an embedded IPv4 tail, with or without
    /// brackets or a `%zone`), a whole number (`3232235777`), or hex or binary
    /// with a prefix (`0xC0A80101`, `0b1100…`).
    static func parse(_ text: String) -> Result<IPAddressInfo, ByteFormatProblem> {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("["), body.hasSuffix("]") { body = String(body.dropFirst().dropLast()) }
        if let zone = body.firstIndex(of: "%") { body = String(body[..<zone]) }
        guard !body.isEmpty else { return .failure(ByteFormatProblem(message: "Type an IP address.")) }

        if body.contains(":") { return parseV6(body) }
        if body.contains(".") { return parseV4(body) }
        // A bare number: decimal, 0x hex or 0b binary — an IPv4 address as one integer.
        switch IntegerInput.parse(body) {
        case .failure(let problem): return .failure(problem)
        case .success(let number):
            guard !number.isNegative, let value = number.magnitude.asUInt64, value <= UInt64(UInt32.max) else {
                if !number.isNegative, number.magnitude.bitLength <= 128 {
                    let bytes = number.magnitude.toBytes()
                    return .success(IPAddressInfo(bytes: [UInt8](repeating: 0, count: 16 - bytes.count) + bytes)!)
                }
                return .failure(ByteFormatProblem(message: "That is larger than an IPv6 address (128 bits)."))
            }
            return .success(IPAddressInfo(bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) })!)
        }
    }

    private static func parseV4(_ text: String) -> Result<IPAddressInfo, ByteFormatProblem> {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else {
            return .failure(ByteFormatProblem(message: "An IPv4 address has four numbers separated by dots; this has \(parts.count)."))
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt8(part) else {
                return .failure(ByteFormatProblem(message: "“\(part)” is not a number from 0 to 255."))
            }
            bytes.append(value)
        }
        return .success(IPAddressInfo(bytes: bytes)!)
    }

    private static func parseV6(_ text: String) -> Result<IPAddressInfo, ByteFormatProblem> {
        let problem = ByteFormatProblem(message: "That is not a valid IPv6 address (eight groups of up to four hex digits, with one :: allowed).")
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return .failure(problem) }

        func groups(_ section: String, allowV4Tail: Bool) -> [UInt16]? {
            if section.isEmpty { return [] }
            var result: [UInt16] = []
            let pieces = section.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            for (index, piece) in pieces.enumerated() {
                if allowV4Tail, index == pieces.count - 1, piece.contains(".") {
                    guard case .success(let v4) = parseV4(piece) else { return nil }
                    result.append(UInt16(v4.bytes[0]) << 8 | UInt16(v4.bytes[1]))
                    result.append(UInt16(v4.bytes[2]) << 8 | UInt16(v4.bytes[3]))
                    continue
                }
                guard !piece.isEmpty, piece.count <= 4, let value = UInt16(piece, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }

        let all: [UInt16]
        if halves.count == 2 {
            guard let head = groups(halves[0], allowV4Tail: false), let tail = groups(halves[1], allowV4Tail: true),
                  head.count + tail.count <= 7 else { return .failure(problem) }
            all = head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard let whole = groups(text, allowV4Tail: true), whole.count == 8 else { return .failure(problem) }
            all = whole
        }
        return .success(IPAddressInfo(bytes: all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })!)
    }

    // MARK: Subnets

    /// An address and a prefix length, and what that makes of the network.
    struct Subnet: Equatable {
        let address: IPAddressInfo
        let prefix: Int

        var bits: Int { address.bytes.count * 8 }

        /// The mask: `prefix` one bits, then zeros.
        var mask: IPAddressInfo {
            IPAddressInfo(bytes: (0..<address.bytes.count).map { byte in
                let ones = max(0, min(8, prefix - byte * 8))
                return ones == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - ones))
            })!
        }

        /// The inverse of the mask (a Cisco "wildcard").
        var wildcard: IPAddressInfo { IPAddressInfo(bytes: mask.bytes.map { ~$0 })! }

        var network: IPAddressInfo { IPAddressInfo(bytes: zip(address.bytes, mask.bytes).map { $0 & $1 })! }

        /// The last address (the broadcast address, for IPv4).
        var last: IPAddressInfo { IPAddressInfo(bytes: zip(network.bytes, wildcard.bytes).map { $0 | $1 })! }

        /// How many addresses the network holds, as a decimal.
        var total: BigNumber {
            var count = BigNumber(UInt64(1))
            for _ in 0..<(bits - prefix) { count.multiply(by: 2, add: 0) }
            return count
        }

        /// Addresses that can be given to hosts: IPv4 loses the network and broadcast
        /// addresses, except a /31 (point-to-point, RFC 3021) and a /32 (one host).
        var usableHosts: String {
            let total = self.total
            // total is at least 4 here, so taking the two off cannot go below zero.
            guard address.isV4, prefix <= 30, let value = total.asUInt64 else { return total.toString(base: 10) }
            return String(value - 2)
        }

        /// The first and last address a host can have.
        var hostRange: (first: IPAddressInfo, last: IPAddressInfo) {
            if address.isV4, prefix <= 30 {
                return (increment(network, by: 1), decrement(last, by: 1))
            }
            return (network, last)
        }

        private func increment(_ info: IPAddressInfo, by amount: UInt8) -> IPAddressInfo {
            var bytes = info.bytes
            var index = bytes.count - 1
            var carry = Int(amount)
            while carry > 0, index >= 0 {
                let sum = Int(bytes[index]) + carry
                bytes[index] = UInt8(sum & 0xFF)
                carry = sum >> 8
                index -= 1
            }
            return IPAddressInfo(bytes: bytes)!
        }

        private func decrement(_ info: IPAddressInfo, by amount: UInt8) -> IPAddressInfo {
            var bytes = info.bytes
            var index = bytes.count - 1
            var borrow = Int(amount)
            while borrow > 0, index >= 0 {
                let value = Int(bytes[index]) - borrow
                bytes[index] = UInt8(truncatingIfNeeded: value)
                borrow = value < 0 ? 1 : 0
                index -= 1
            }
            return IPAddressInfo(bytes: bytes)!
        }

        /// Whether `other` is inside this network.
        func contains(_ other: IPAddressInfo) -> Bool {
            other.bytes.count == address.bytes.count && IPAddressInfo.matches(other.bytes, network.bytes, prefix)
        }
    }

    /// `192.168.1.10/24`, `10.0.0.0/8`, `2001:db8::/32`, or an address with a
    /// netmask: `192.168.1.10 255.255.255.0`.
    static func parseSubnet(_ text: String) -> Result<Subnet, ByteFormatProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var addressText = trimmed
        var prefix: Int?
        if let slash = trimmed.firstIndex(of: "/") {
            addressText = String(trimmed[..<slash])
            let prefixText = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            guard let value = Int(prefixText), value >= 0 else {
                return .failure(ByteFormatProblem(message: "After the / goes a number of bits, like /24."))
            }
            prefix = value
        } else if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            addressText = String(trimmed[..<space])
            let maskText = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard case .success(let mask) = parse(maskText), mask.isV4 else {
                return .failure(ByteFormatProblem(message: "After the address goes a netmask like 255.255.255.0."))
            }
            let value = mask.bytes.reduce(0) { $0 << 8 | UInt32($1) }
            let ones = value.nonzeroBitCount
            guard value == (ones == 0 ? 0 : UInt32.max << UInt32(32 - ones)) else {
                return .failure(ByteFormatProblem(message: "A netmask is ones and then zeros; \(maskText) has a gap."))
            }
            prefix = ones
        }
        switch parse(addressText) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let address):
            let chosen = prefix ?? address.bytes.count * 8
            guard chosen <= address.bytes.count * 8 else {
                return .failure(ByteFormatProblem(message: "/\(chosen) is too long: an IPv\(address.version) address has \(address.bytes.count * 8) bits."))
            }
            return .success(Subnet(address: address, prefix: chosen))
        }
    }
}
