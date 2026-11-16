import Foundation

/// A captured packet taken apart, layer by layer: Ethernet, then IP, then TCP or UDP or
/// ICMP, each header a group of fields tied to its bytes, in the order they are on the wire.
///
/// The layers are siblings, not nested, as in Wireshark: a byte of the TCP header is in the
/// TCP group, and the IP header before it is its own group. Everything that is read is read
/// through a `ByteWindow` of the packet, so a packet cut short by the capture's snap length
/// — or one that lies about its lengths — ends in a "cut off" field, never a read outside.
///
/// What it knows is what a person studying a capture needs to see the shape of: addresses,
/// protocols, ports, flags, options. It does not follow what is inside TCP or UDP, and it
/// does not check checksums: a capture taken on the machine that sent the packet very often
/// holds checksums the network card had not filled in yet, and calling those wrong would be
/// a false alarm about nothing.
enum PacketDissector {
    struct Result {
        var nodes: [FieldNode]
        /// One line: "TCP 10.0.0.1:51514 → 93.184.216.34:80 [SYN]".
        var summary: String
    }

    /// What is found on the way down, for the summary line.
    private final class Facts {
        var vlans: [Int] = []
        var network = ""
        var transport = ""
        var source: String?
        var destination: String?
        var ports: (UInt64, UInt64)?
        var detail: String?
        var other: String?
        var isIPv6 = false

        func line() -> String {
            var prefix = ""
            if !vlans.isEmpty { prefix = "VLAN " + vlans.map { String($0) }.joined(separator: ",") + " · " }
            if let other { return prefix + other }
            let name = transport.isEmpty ? network : transport
            guard !name.isEmpty else { return prefix + "no protocol" }
            var text = name
            if let source, let destination {
                if let ports {
                    let from = isIPv6 ? "[\(source)]:\(ports.0)" : "\(source):\(ports.0)"
                    let to = isIPv6 ? "[\(destination)]:\(ports.1)" : "\(destination):\(ports.1)"
                    text += " \(from) → \(to)"
                } else {
                    text += " \(source) → \(destination)"
                }
            }
            if let detail { text += " " + detail }
            return prefix + text
        }
    }

    /// The packet in `window`, which starts at the packet's first byte, as `linkType` says.
    /// With `recording` off only the summary is worked out.
    static func dissect(linkType: UInt32, window: ByteWindow, idPrefix: String, recording: Bool = true) -> Result {
        var list = FieldList(idPrefix: idPrefix, window: window, endianness: .big, recording: recording)
        let facts = Facts()
        let start = window.base
        switch linkType {
        case 1:
            ethernet(&list, at: start, facts: facts)
        case 0:
            loopback(&list, at: start, facts: facts)
        case 113:
            linuxCooked(&list, at: start, facts: facts)
        case 12, 14, 101, 228, 229:
            rawIP(&list, at: start, facts: facts)
        default:
            facts.other = "link type \(linkType) is not dissected"
            list.bytes("Packet data", at: start, length: Int64(window.bytes.count),
                       note: "Link type \(PacketNames.linkType(linkType)) is not taken apart here; the bytes are in the dump.")
        }
        return Result(nodes: list.nodes, summary: facts.line())
    }

    // MARK: Link layers

    private static func ethernet(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        var etherType: UInt64?
        list.group("Ethernet II", at: offset, length: 14) { f in
            let destination = f.address("Destination", at: offset, size: 6, format: PacketNames.mac)
            let source = f.address("Source", at: offset + 6, size: 6, format: PacketNames.mac)
            etherType = f.uint("Type", at: offset + 12, size: 2, value: PacketNames.etherType)
            if let source, let destination {
                f.groupValue = PacketNames.mac(source) + " → " + PacketNames.mac(destination)
            }
        }
        guard var type = etherType else { return }
        var next = offset + 14
        var tags = 0
        while type == 0x8100 || type == 0x88A8, tags < 4 {
            var inner: UInt64?
            let tagAt = next
            list.group("802.1Q VLAN tag", at: tagAt, length: 4) { f in
                f.bits("Priority", at: tagAt, size: 2, shift: 13, width: 3)
                f.bits("Drop eligible", at: tagAt, size: 2, shift: 12, width: 1, value: { $0 == 1 ? "yes" : "no" })
                if let vlan = f.bits("VLAN ID", at: tagAt, size: 2, shift: 0, width: 12) {
                    facts.vlans.append(Int(vlan))
                    f.groupValue = "VLAN \(vlan)"
                }
                inner = f.uint("Type", at: tagAt + 2, size: 2, value: PacketNames.etherType)
            }
            guard let found = inner else { return }
            type = found
            next += 4
            tags += 1
        }
        network(&list, etherType: type, at: next, facts: facts)
    }

    /// The four-byte family the BSDs put in front of a loopback packet, in the byte order of
    /// the machine that captured it: told by which way round gives a small number.
    private static func loopback(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        let raw = list.window.u32(offset, .little) ?? 0
        let order: Endianness = raw <= 255 ? .little : .big
        list.endianness = order
        list.group("Loopback header", at: offset, length: 4) { f in
            f.uint("Family", at: offset, size: 4, value: { value in
                switch value {
                case 2: return "2 · IPv4"
                case 10, 24, 28, 30: return "\(value) · IPv6"
                default: return "\(value)"
                }
            })
        }
        list.endianness = .big
        guard !list.truncated else { return }
        rawIP(&list, at: offset + 4, facts: facts)
    }

    private static func linuxCooked(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        var protocolType: UInt64?
        list.group("Linux cooked capture", at: offset, length: 16) { f in
            f.uint("Packet type", at: offset, size: 2, value: { value in
                let names = ["0 · to us", "1 · broadcast", "2 · multicast", "3 · to someone else", "4 · from us"]
                return value < 5 ? names[Int(value)] : "\(value)"
            })
            f.uint("Hardware type", at: offset + 2, size: 2, value: PacketNames.arpHardware)
            let length = f.uint("Address length", at: offset + 4, size: 2)
            f.bytes("Address", at: offset + 6, length: 8, value: f.window.slice(offset + 6, Int(min(length ?? 0, 8)))
                .map { PacketNames.address(Array($0)) })
            protocolType = f.uint("Protocol", at: offset + 14, size: 2, value: PacketNames.etherType)
        }
        guard let type = protocolType else { return }
        network(&list, etherType: type, at: offset + 16, facts: facts)
    }

    /// A packet with no link header: IPv4 or IPv6, told by the first nibble.
    private static func rawIP(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        guard let first = list.window.u8(offset) else { return }
        switch first >> 4 {
        case 4: ipv4(&list, at: offset, facts: facts)
        case 6: ipv6(&list, at: offset, facts: facts)
        default:
            facts.other = "not IPv4 or IPv6"
            payload(&list, "Packet data", from: offset, to: list.window.end, declaredEnd: list.window.end,
                    note: "The first nibble is \(first >> 4), not 4 or 6, so this is not an IP packet.")
        }
    }

    // MARK: Network layers

    private static func network(_ list: inout FieldList, etherType: UInt64, at offset: Int64, facts: Facts) {
        switch etherType {
        case 0x0800:
            ipv4(&list, at: offset, facts: facts)
        case 0x86DD:
            ipv6(&list, at: offset, facts: facts)
        case 0x0806:
            arp(&list, at: offset, facts: facts)
        default:
            if etherType < 0x0600 {
                facts.other = "802.3 frame, length \(etherType)"
            } else {
                let name = PacketNames.etherTypes[etherType].map { " (\($0))" } ?? ""
                facts.other = "Ethernet type " + FieldText.hexNumber(etherType, size: 2) + name
            }
            payload(&list, "Payload", from: offset, to: list.window.end, declaredEnd: list.window.end,
                    note: "This type is not taken apart here; the bytes are in the dump.")
        }
    }

    private static func arp(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        facts.network = "ARP"
        let hardwareSize = Int(list.window.u8(offset + 4) ?? 6)
        let protocolSize = Int(list.window.u8(offset + 5) ?? 4)
        let length = Int64(8 + 2 * hardwareSize + 2 * protocolSize)
        list.group("ARP", at: offset, length: length) { f in
            f.uint("Hardware type", at: offset, size: 2, value: PacketNames.arpHardware)
            f.uint("Protocol type", at: offset + 2, size: 2, value: PacketNames.etherType)
            f.uint("Hardware size", at: offset + 4, size: 1)
            f.uint("Protocol size", at: offset + 5, size: 1)
            let opcode = f.uint("Opcode", at: offset + 6, size: 2, value: PacketNames.arpOpcode)
            var cursor = offset + 8
            let senderHardware = f.address("Sender hardware address", at: cursor, size: hardwareSize, format: PacketNames.address)
            cursor += Int64(hardwareSize)
            let senderProtocol = f.address("Sender protocol address", at: cursor, size: protocolSize, format: PacketNames.address)
            cursor += Int64(protocolSize)
            f.address("Target hardware address", at: cursor, size: hardwareSize, format: PacketNames.address)
            cursor += Int64(hardwareSize)
            let targetProtocol = f.address("Target protocol address", at: cursor, size: protocolSize, format: PacketNames.address)
            if let sender = senderProtocol.map(PacketNames.address), let target = targetProtocol.map(PacketNames.address) {
                switch opcode {
                case 1?:
                    facts.detail = "who-has \(target) tell \(sender)"
                case 2?:
                    let at = senderHardware.map(PacketNames.address) ?? "?"
                    facts.detail = "\(sender) is at \(at)"
                default:
                    facts.detail = "opcode \(opcode.map { String($0) } ?? "?")"
                }
                f.groupValue = facts.detail
            }
        }
        guard !list.truncated else { return }
        let end = offset + length
        if list.window.end > end {
            list.bytes("Padding", at: end, length: list.window.end - end, kind: .padding,
                       note: "Ethernet pads short frames to 60 bytes. The padding is not part of the ARP message.")
        }
    }

    private static func ipv4(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        facts.network = "IPv4"
        let first = list.window.u8(offset) ?? 0x45
        let words = Int(first & 0x0F)
        let headerLength = Int64(max(words, 5)) * 4
        var protocolNumber: UInt64?
        var totalLength: UInt64?
        var fragmentOffset: UInt64 = 0
        var moreFragments = false
        list.group("IPv4", at: offset, length: headerLength) { f in
            f.bits("Version", at: offset, size: 1, shift: 4, width: 4, note: "The high four bits of the first byte.")
            f.bits("Header length", at: offset, size: 1, shift: 0, width: 4,
                   value: { "\($0) words (\($0 * 4) bytes)" },
                   note: words < 5 ? "Less than the minimum of 5 words; read as 5." : "The low four bits of the first byte, in 4-byte words.")
            f.uint("Differentiated services", at: offset + 1, size: 1, value: { "DSCP \($0 >> 2), ECN \($0 & 3)" })
            totalLength = f.uint("Total length", at: offset + 2, size: 2, value: { "\($0) bytes, header included" })
            f.uint("Identification", at: offset + 4, size: 2, value: { FieldText.hexNumber($0, size: 2) + " (\($0))" })
            f.bits("Flags", at: offset + 6, size: 2, shift: 13, width: 3, kind: .flags, value: { bits in
                var names: [String] = []
                if bits & 2 != 0 { names.append("don't fragment") }
                if bits & 1 != 0 { names.append("more fragments") }
                if bits & 4 != 0 { names.append("reserved bit set") }
                return names.isEmpty ? "none" : names.joined(separator: ", ")
            })
            if let bits = f.window.u16(offset + 6, .big) {
                moreFragments = (bits >> 13) & 1 == 1
            }
            fragmentOffset = f.bits("Fragment offset", at: offset + 6, size: 2, shift: 0, width: 13,
                                    value: { "\($0 * 8) bytes" }) ?? 0
            f.uint("Time to live", at: offset + 8, size: 1)
            protocolNumber = f.uint("Protocol", at: offset + 9, size: 1, value: PacketNames.ipProtocol)
            f.uint("Header checksum", at: offset + 10, size: 2, kind: .checksum, value: { FieldText.hexNumber($0, size: 2) },
                   note: { _ in "Not checked here: a capture taken on the sending machine often holds checksums the network card had not filled in yet." })
            let source = f.address("Source", at: offset + 12, size: 4, format: PacketNames.ipv4)
            let destination = f.address("Destination", at: offset + 16, size: 4, format: PacketNames.ipv4)
            if let source, let destination {
                facts.source = PacketNames.ipv4(source)
                facts.destination = PacketNames.ipv4(destination)
                f.groupValue = PacketNames.ipv4(source) + " → " + PacketNames.ipv4(destination)
            }
            if headerLength > 20 {
                f.bytes("Options", at: offset + 20, length: headerLength - 20, note: "Rarely used: record route, timestamps, source routing.")
            }
        }
        guard !list.truncated else { return }
        let payloadStart = offset + headerLength
        var declaredEnd = list.window.end
        if let total = totalLength, Int64(total) >= headerLength { declaredEnd = offset + Int64(total) }
        let payloadEnd = min(declaredEnd, list.window.end)

        if fragmentOffset == 0 {
            switch protocolNumber {
            case 6?: tcp(&list, at: payloadStart, end: payloadEnd, declaredEnd: declaredEnd, facts: facts)
            case 17?: udp(&list, at: payloadStart, end: payloadEnd, declaredEnd: declaredEnd, facts: facts)
            case 1?: icmp(&list, at: payloadStart, end: payloadEnd, declaredEnd: declaredEnd, facts: facts)
            default:
                facts.transport = protocolNumber.map { PacketNames.ipProtocols[$0] ?? "protocol \($0)" } ?? ""
                payload(&list, "Payload", from: payloadStart, to: payloadEnd, declaredEnd: declaredEnd,
                        note: moreFragments ? "The first fragment of a split packet." : "This protocol is not taken apart here.")
            }
        } else {
            facts.transport = "IPv4 fragment"
            facts.detail = "at \(fragmentOffset * 8)"
            payload(&list, "Fragment", from: payloadStart, to: payloadEnd, declaredEnd: declaredEnd,
                    note: "Not the first fragment, so it has no transport header of its own: it is a piece of the middle or the end of one.")
        }
        trailing(&list, from: payloadEnd)
    }

    private static func ipv6(_ list: inout FieldList, at offset: Int64, facts: Facts) {
        facts.network = "IPv6"
        facts.isIPv6 = true
        var next: UInt64?
        var payloadLength: UInt64?
        list.group("IPv6", at: offset, length: 40) { f in
            f.bits("Version", at: offset, size: 1, shift: 4, width: 4, note: "The high four bits of the first byte.")
            f.bits("Traffic class", at: offset, size: 2, shift: 4, width: 8, value: { "DSCP \($0 >> 2), ECN \($0 & 3)" })
            f.bits("Flow label", at: offset, size: 4, shift: 0, width: 20, value: { FieldText.hexNumber($0, size: 3) })
            payloadLength = f.uint("Payload length", at: offset + 4, size: 2, value: { "\($0) bytes after this header" })
            next = f.uint("Next header", at: offset + 6, size: 1, value: PacketNames.ipProtocol)
            f.uint("Hop limit", at: offset + 7, size: 1)
            let source = f.address("Source", at: offset + 8, size: 16, format: PacketNames.ipv6)
            let destination = f.address("Destination", at: offset + 24, size: 16, format: PacketNames.ipv6)
            if let source, let destination {
                facts.source = PacketNames.ipv6(source)
                facts.destination = PacketNames.ipv6(destination)
                f.groupValue = PacketNames.ipv6(source) + " → " + PacketNames.ipv6(destination)
            }
        }
        guard !list.truncated else { return }

        // Extension headers, each saying what comes next.
        var cursor = offset + 40
        var hops = 0
        var isFragment = false
        while let kind = next, [0, 43, 44, 51, 60].contains(kind), hops < 8 {
            let start = cursor
            var following: UInt64?
            let units = Int64(list.window.u8(start + 1) ?? 0)
            switch kind {
            case 44:
                list.group("IPv6 fragment header", at: start, length: 8) { f in
                    following = f.uint("Next header", at: start, size: 1, value: PacketNames.ipProtocol)
                    f.bytes("Reserved", at: start + 1, length: 1, kind: .padding)
                    let fragment = f.bits("Fragment offset", at: start + 2, size: 2, shift: 3, width: 13, value: { "\($0 * 8) bytes" })
                    f.bits("More fragments", at: start + 2, size: 2, shift: 0, width: 1, value: { $0 == 1 ? "yes" : "no" })
                    f.uint("Identification", at: start + 4, size: 4)
                    if let fragment, fragment != 0 { isFragment = true }
                }
                cursor += 8
            default:
                let length = kind == 51 ? (units + 2) * 4 : (units + 1) * 8
                let name = kind == 0 ? "IPv6 hop-by-hop options" : (kind == 43 ? "IPv6 routing header" : (kind == 51 ? "Authentication header" : "IPv6 destination options"))
                list.group(name, at: start, length: length) { f in
                    following = f.uint("Next header", at: start, size: 1, value: PacketNames.ipProtocol)
                    f.uint("Header length", at: start + 1, size: 1, value: { "\($0) · \(length) bytes in all" })
                    if length > 2 { f.bytes("Data", at: start + 2, length: length - 2) }
                }
                cursor += length
            }
            guard !list.truncated, let found = following else { return }
            next = found
            hops += 1
        }

        var declaredEnd = list.window.end
        if let length = payloadLength, length > 0 { declaredEnd = offset + 40 + Int64(length) }
        let payloadEnd = min(declaredEnd, list.window.end)

        if isFragment {
            facts.transport = "IPv6 fragment"
            payload(&list, "Fragment", from: cursor, to: payloadEnd, declaredEnd: declaredEnd,
                    note: "Not the first fragment, so it has no transport header of its own.")
        } else {
            switch next {
            case 6?: tcp(&list, at: cursor, end: payloadEnd, declaredEnd: declaredEnd, facts: facts)
            case 17?: udp(&list, at: cursor, end: payloadEnd, declaredEnd: declaredEnd, facts: facts)
            case 58?: icmpv6(&list, at: cursor, end: payloadEnd, declaredEnd: declaredEnd, facts: facts)
            case 50?:
                facts.transport = "ESP"
                payload(&list, "Encrypted payload (ESP)", from: cursor, to: payloadEnd, declaredEnd: declaredEnd,
                        note: "Encapsulating Security Payload: encrypted, so there is nothing to read.")
            default:
                facts.transport = next.map { PacketNames.ipProtocols[$0] ?? "protocol \($0)" } ?? ""
                payload(&list, "Payload", from: cursor, to: payloadEnd, declaredEnd: declaredEnd,
                        note: "This protocol is not taken apart here.")
            }
        }
        trailing(&list, from: payloadEnd)
    }

    // MARK: Transport layers

    private static func tcp(_ list: inout FieldList, at offset: Int64, end: Int64, declaredEnd: Int64, facts: Facts) {
        facts.transport = "TCP"
        let words = Int64(max(Int((list.window.u8(offset + 12) ?? 0x50) >> 4), 5))
        let headerLength = words * 4
        let raw = UInt64(list.window.u16(offset + 12, .big) ?? 0) & 0x0FFF
        var sourcePort: UInt64?
        var destinationPort: UInt64?
        let flags = flagNames(raw)
        list.group("TCP", at: offset, length: headerLength) { f in
            sourcePort = f.uint("Source port", at: offset, size: 2, value: PacketNames.port)
            destinationPort = f.uint("Destination port", at: offset + 2, size: 2, value: PacketNames.port)
            f.uint("Sequence number", at: offset + 4, size: 4)
            f.uint("Acknowledgment number", at: offset + 8, size: 4)
            f.bits("Header length", at: offset + 12, size: 1, shift: 4, width: 4, value: { "\($0) words (\($0 * 4) bytes)" })
            f.group("Flags", at: offset + 12, length: 2, kind: .flags, value: flags.isEmpty ? "none" : flags.joined(separator: ", ")) { g in
                g.bits("Reserved", at: offset + 12, size: 2, shift: 9, width: 3)
                let bits: [(String, Int)] = [("Nonce (NS)", 8), ("CWR", 7), ("ECE", 6), ("URG", 5), ("ACK", 4),
                                             ("PSH", 3), ("RST", 2), ("SYN", 1), ("FIN", 0)]
                for (name, shift) in bits {
                    g.bits(name, at: offset + 12, size: 2, shift: shift, width: 1, kind: .flags,
                           value: { $0 == 1 ? "set" : "not set" })
                }
            }
            f.uint("Window", at: offset + 14, size: 2, value: { "\($0) bytes" })
            f.uint("Checksum", at: offset + 16, size: 2, kind: .checksum, value: { FieldText.hexNumber($0, size: 2) })
            f.uint("Urgent pointer", at: offset + 18, size: 2)
            if headerLength > 20 { tcpOptions(&f, from: offset + 20, to: offset + headerLength) }
            if let sourcePort, let destinationPort {
                f.groupValue = "\(sourcePort) → \(destinationPort)" + (flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]")
            }
        }
        if let sourcePort, let destinationPort { facts.ports = (sourcePort, destinationPort) }
        if !flags.isEmpty { facts.detail = "[" + flags.joined(separator: ", ") + "]" }
        guard !list.truncated else { return }
        payload(&list, "Payload", from: offset + headerLength, to: end, declaredEnd: declaredEnd,
                note: portHint(sourcePort, destinationPort))
    }

    private static func tcpOptions(_ list: inout FieldList, from start: Int64, to end: Int64) {
        list.group("Options", at: start, length: end - start) { o in
            var cursor = start
            var count = 0
            while cursor < end, count < 40, !o.truncated {
                guard let kind = o.window.u8(cursor) else { break }
                if kind == 0 {
                    o.bytes("End of option list", at: cursor, length: end - cursor, kind: .padding,
                            note: "Zero bytes to the end of the header.")
                    break
                }
                if kind == 1 {
                    o.bytes("No-operation", at: cursor, length: 1, kind: .padding, note: "A filler byte that keeps the next option aligned.")
                    cursor += 1
                    count += 1
                    continue
                }
                let length = Int64(o.window.u8(cursor + 1) ?? 0)
                if length < 2 || cursor + length > end {
                    o.problem("Option \(kind) has a length of \(length), which does not fit in the \(end - cursor) bytes left.",
                              at: cursor, length: end - cursor, name: "Bad option")
                    break
                }
                let slice = o.window.slice(cursor, Int(length))
                o.bytes(PacketNames.tcpOption(kind), at: cursor, length: length,
                        value: slice.flatMap { tcpOptionValue(kind: kind, bytes: Array($0)) })
                cursor += length
                count += 1
            }
        }
    }

    private static func tcpOptionValue(kind: UInt8, bytes: [UInt8]) -> String? {
        switch kind {
        case 2 where bytes.count == 4:
            return String(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        case 3 where bytes.count == 3:
            return "shift \(bytes[2]), × \(1 << Int(min(bytes[2], 14)))"
        case 4:
            return "yes"
        case 5:
            return "\((bytes.count - 2) / 8) blocks"
        case 8 where bytes.count == 10:
            let value = UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5])
            let echo = UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 8 | UInt32(bytes[9])
            return "value \(value), echo \(echo)"
        default:
            return nil
        }
    }

    private static func udp(_ list: inout FieldList, at offset: Int64, end: Int64, declaredEnd: Int64, facts: Facts) {
        facts.transport = "UDP"
        var sourcePort: UInt64?
        var destinationPort: UInt64?
        var length: UInt64?
        list.group("UDP", at: offset, length: 8) { f in
            sourcePort = f.uint("Source port", at: offset, size: 2, value: PacketNames.port)
            destinationPort = f.uint("Destination port", at: offset + 2, size: 2, value: PacketNames.port)
            length = f.uint("Length", at: offset + 4, size: 2, value: { "\($0) bytes, header included" })
            f.uint("Checksum", at: offset + 6, size: 2, kind: .checksum, value: { FieldText.hexNumber($0, size: 2) })
            if let sourcePort, let destinationPort { f.groupValue = "\(sourcePort) → \(destinationPort)" }
        }
        if let sourcePort, let destinationPort { facts.ports = (sourcePort, destinationPort) }
        guard !list.truncated else { return }
        var udpEnd = end
        var udpDeclared = declaredEnd
        if let length, length >= 8 {
            udpDeclared = min(declaredEnd, offset + Int64(length))
            udpEnd = min(end, udpDeclared)
        }
        payload(&list, "Payload", from: offset + 8, to: udpEnd, declaredEnd: udpDeclared,
                note: portHint(sourcePort, destinationPort))
    }

    private static func icmp(_ list: inout FieldList, at offset: Int64, end: Int64, declaredEnd: Int64, facts: Facts) {
        facts.transport = "ICMP"
        var type: UInt64?
        list.group("ICMP", at: offset, length: 8) { f in
            type = f.uint("Type", at: offset, size: 1, value: PacketNames.icmpType)
            f.uint("Code", at: offset + 1, size: 1)
            f.uint("Checksum", at: offset + 2, size: 2, kind: .checksum, value: { FieldText.hexNumber($0, size: 2) })
            if type == 0 || type == 8 {
                f.uint("Identifier", at: offset + 4, size: 2)
                f.uint("Sequence number", at: offset + 6, size: 2)
            } else {
                f.bytes("Rest of header", at: offset + 4, length: 4)
            }
            if let type { f.groupValue = PacketNames.words(PacketNames.icmpType(type)) }
        }
        if let type { facts.detail = PacketNames.words(PacketNames.icmpType(type)) }
        guard !list.truncated else { return }
        payload(&list, "Data", from: offset + 8, to: end, declaredEnd: declaredEnd, note: nil)
    }

    private static func icmpv6(_ list: inout FieldList, at offset: Int64, end: Int64, declaredEnd: Int64, facts: Facts) {
        facts.transport = "ICMPv6"
        var type: UInt64?
        list.group("ICMPv6", at: offset, length: 8) { f in
            type = f.uint("Type", at: offset, size: 1, value: PacketNames.icmpv6Type)
            f.uint("Code", at: offset + 1, size: 1)
            f.uint("Checksum", at: offset + 2, size: 2, kind: .checksum, value: { FieldText.hexNumber($0, size: 2) })
            if type == 128 || type == 129 {
                f.uint("Identifier", at: offset + 4, size: 2)
                f.uint("Sequence number", at: offset + 6, size: 2)
            } else {
                f.bytes("Rest of header", at: offset + 4, length: 4)
            }
            if let type { f.groupValue = PacketNames.words(PacketNames.icmpv6Type(type)) }
        }
        if let type { facts.detail = PacketNames.words(PacketNames.icmpv6Type(type)) }
        guard !list.truncated else { return }
        payload(&list, "Data", from: offset + 8, to: end, declaredEnd: declaredEnd, note: nil)
    }

    // MARK: Pieces

    /// The bytes from `start` to `end`, as a field of their own, and said to be cut short if
    /// the packet claims more than the capture kept.
    private static func payload(_ list: inout FieldList, _ name: String, from start: Int64, to end: Int64,
                                declaredEnd: Int64, note: String?) {
        let stop = min(end, list.window.end)
        guard stop > start else { return }
        let preview = list.window.slice(start, Int(min(stop - start, 64)))
        var text = note
        if declaredEnd > list.window.end {
            let cut = "Cut short by the capture: the packet says \(FieldText.bytes(declaredEnd - start)) are here and the file kept \(FieldText.bytes(stop - start))."
            text = note.map { cut + " " + $0 } ?? cut
        }
        list.bytes(name, at: start, length: stop - start, value: preview.map { previewText($0) }, note: text)
    }

    /// What follows the end of an IP packet in a frame: padding.
    private static func trailing(_ list: inout FieldList, from end: Int64) {
        guard !list.truncated, list.window.end > end else { return }
        list.bytes("Padding", at: end, length: list.window.end - end, kind: .padding,
                   note: "Ethernet pads short frames to 60 bytes. The padding is not part of the IP packet.")
    }

    /// Text if it reads as text, else hex.
    private static func previewText(_ bytes: ArraySlice<UInt8>) -> String {
        let printable = bytes.filter { HexGeometry.isPrintable($0) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }.count
        guard !bytes.isEmpty, printable * 10 >= bytes.count * 9 else { return FieldText.hex(bytes) }
        var text = ""
        for byte in bytes.prefix(48) {
            switch byte {
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            default: text.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return "\"" + text + (bytes.count > 48 ? "…" : "") + "\""
    }

    private static func flagNames(_ raw: UInt64) -> [String] {
        let order: [(String, UInt64)] = [("SYN", 0x02), ("FIN", 0x01), ("RST", 0x04), ("PSH", 0x08), ("ACK", 0x10),
                                         ("URG", 0x20), ("ECE", 0x40), ("CWR", 0x80), ("NS", 0x100)]
        return order.filter { raw & $0.1 != 0 }.map { $0.0 }
    }

    private static func portHint(_ source: UInt64?, _ destination: UInt64?) -> String? {
        for port in [destination, source] {
            if let port, let name = PacketNames.ports[port] {
                return "Port \(port) is usually \(name)."
            }
        }
        return nil
    }
}
