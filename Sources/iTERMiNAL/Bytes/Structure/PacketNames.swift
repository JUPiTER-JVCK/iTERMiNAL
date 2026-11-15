import Foundation

/// The names a packet's numbers have: what an EtherType, an IP protocol or a port is
/// called, and how an address is written. Plain tables, checked for the entries the
/// rest of the dissector depends on.
enum PacketNames {
    // MARK: Addresses

    /// "00:11:22:33:44:55".
    static func mac(_ bytes: [UInt8]) -> String {
        bytes.map { ByteRadix.hex.cell($0).lowercased() }.joined(separator: ":")
    }

    /// "10.0.0.1".
    static func ipv4(_ bytes: [UInt8]) -> String {
        bytes.map { String($0) }.joined(separator: ".")
    }

    /// An IPv6 address as RFC 5952 writes it: lower case, the longest run of zero groups
    /// (two or more) as `::`, no leading zeros.
    static func ipv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return bytes.map { ByteRadix.hex.cell($0).lowercased() }.joined(separator: ":") }
        var groups: [UInt16] = []
        for i in stride(from: 0, to: 16, by: 2) {
            groups.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
        }
        // The longest run of zeros, the first if two are as long.
        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        var runLength = 0
        for (index, group) in groups.enumerated() {
            if group == 0 {
                if runStart < 0 { runStart = index }
                runLength += 1
                if runLength > bestLength {
                    bestLength = runLength
                    bestStart = runStart
                }
            } else {
                runStart = -1
                runLength = 0
            }
        }
        if bestLength < 2 { bestStart = -1 }

        var text = ""
        var index = 0
        while index < 8 {
            if index == bestStart {
                text += "::"
                index += bestLength
                continue
            }
            if !text.isEmpty, !text.hasSuffix(":") { text += ":" }
            text += String(groups[index], radix: 16)
            index += 1
        }
        return text.isEmpty ? "::" : text
    }

    /// An address of whatever size: a MAC, an IPv4 or an IPv6 by its length, else hex.
    static func address(_ bytes: [UInt8]) -> String {
        switch bytes.count {
        case 4: return ipv4(bytes)
        case 6: return mac(bytes)
        case 16: return ipv6(bytes)
        default: return bytes.map { ByteRadix.hex.cell($0) }.joined(separator: " ")
        }
    }

    // MARK: Numbers

    static func etherType(_ value: UInt64) -> String {
        let hex = FieldText.hexNumber(value, size: 2)
        if value < 0x0600 { return "\(value) · an 802.3 length, not a type" }
        if let name = etherTypes[value] { return "\(name) (\(hex))" }
        return hex
    }

    static let etherTypes: [UInt64: String] = [
        0x0800: "IPv4", 0x0806: "ARP", 0x0842: "Wake-on-LAN", 0x22F3: "TRILL", 0x8035: "RARP",
        0x809B: "AppleTalk", 0x80F3: "AppleTalk ARP", 0x8100: "802.1Q VLAN", 0x86DD: "IPv6",
        0x8808: "Ethernet flow control", 0x8847: "MPLS unicast", 0x8848: "MPLS multicast",
        0x8863: "PPPoE discovery", 0x8864: "PPPoE session", 0x888E: "802.1X", 0x88A8: "802.1ad VLAN",
        0x88CC: "LLDP", 0x88E5: "MACsec", 0x88F7: "PTP", 0x8906: "FCoE",
    ]

    static func ipProtocol(_ value: UInt64) -> String {
        if let name = ipProtocols[value] { return "\(name) (\(value))" }
        return "\(value)"
    }

    static let ipProtocols: [UInt64: String] = [
        0: "IPv6 hop-by-hop options", 1: "ICMP", 2: "IGMP", 4: "IP in IP", 6: "TCP", 17: "UDP", 41: "IPv6 in IP",
        43: "IPv6 routing", 44: "IPv6 fragment", 47: "GRE", 50: "ESP", 51: "AH", 58: "ICMPv6", 59: "no next header",
        60: "IPv6 destination options", 89: "OSPF", 103: "PIM", 112: "VRRP", 132: "SCTP",
    ]

    static func port(_ value: UInt64) -> String {
        if let name = ports[value] { return "\(value) · \(name)" }
        return "\(value)"
    }

    static let ports: [UInt64: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP server", 68: "DHCP client",
        69: "TFTP", 80: "HTTP", 110: "POP3", 119: "NNTP", 123: "NTP", 137: "NetBIOS name", 138: "NetBIOS datagram",
        139: "NetBIOS session", 143: "IMAP", 161: "SNMP", 162: "SNMP trap", 179: "BGP", 389: "LDAP", 443: "HTTPS",
        445: "SMB", 465: "SMTPS", 514: "syslog", 546: "DHCPv6 client", 547: "DHCPv6 server", 587: "SMTP submission",
        631: "IPP", 636: "LDAPS", 853: "DNS over TLS", 993: "IMAPS", 995: "POP3S", 1433: "SQL Server", 1883: "MQTT",
        3306: "MySQL", 3389: "RDP", 5060: "SIP", 5353: "mDNS", 5432: "PostgreSQL", 5900: "VNC", 6379: "Redis",
        8080: "HTTP alternate", 8443: "HTTPS alternate",
    ]

    static func linkType(_ value: UInt32) -> String {
        if let name = linkTypes[value] { return "\(name) (\(value))" }
        return "\(value)"
    }

    static let linkTypes: [UInt32: String] = [
        0: "BSD loopback", 1: "Ethernet", 6: "Token Ring", 9: "PPP", 12: "raw IP (BSD)", 14: "raw IP (OpenBSD)",
        101: "raw IP", 104: "Cisco HDLC", 105: "802.11 Wi-Fi", 108: "OpenBSD loopback", 113: "Linux cooked",
        127: "802.11 with radiotap", 143: "DOCSIS", 147: "private use 0", 192: "PPI", 228: "raw IPv4", 229: "raw IPv6",
        276: "Linux cooked v2",
    ]

    static func arpOpcode(_ value: UInt64) -> String {
        switch value {
        case 1: return "1 · request"
        case 2: return "2 · reply"
        case 3: return "3 · reverse request"
        case 4: return "4 · reverse reply"
        default: return "\(value)"
        }
    }

    static func arpHardware(_ value: UInt64) -> String {
        value == 1 ? "1 · Ethernet" : "\(value)"
    }

    static func icmpType(_ value: UInt64) -> String {
        let names: [UInt64: String] = [
            0: "echo reply", 3: "destination unreachable", 4: "source quench", 5: "redirect", 8: "echo request",
            9: "router advertisement", 10: "router solicitation", 11: "time exceeded", 12: "parameter problem",
            13: "timestamp request", 14: "timestamp reply",
        ]
        return names[value].map { "\(value) · \($0)" } ?? "\(value)"
    }

    static func icmpv6Type(_ value: UInt64) -> String {
        let names: [UInt64: String] = [
            1: "destination unreachable", 2: "packet too big", 3: "time exceeded", 4: "parameter problem",
            128: "echo request", 129: "echo reply", 130: "multicast listener query", 131: "multicast listener report",
            133: "router solicitation", 134: "router advertisement", 135: "neighbour solicitation",
            136: "neighbour advertisement", 137: "redirect", 143: "multicast listener report v2",
        ]
        return names[value].map { "\(value) · \($0)" } ?? "\(value)"
    }

    /// "echo request" for the summary line: the words without the number.
    static func words(_ labelled: String) -> String {
        guard let dot = labelled.range(of: " · ") else { return labelled }
        return String(labelled[dot.upperBound...])
    }

    static func tcpOption(_ kind: UInt8) -> String {
        let names: [UInt8: String] = [
            0: "End of option list", 1: "No-operation", 2: "Maximum segment size", 3: "Window scale",
            4: "SACK permitted", 5: "SACK blocks", 8: "Timestamps", 28: "User timeout", 29: "Authentication",
            30: "Multipath TCP", 34: "Fast Open cookie",
        ]
        return names[kind] ?? "Option \(kind)"
    }

    /// "10:04:05.123456" from seconds since the epoch, the day's own clock in UTC.
    static func clock(seconds: Int64, fraction: UInt64, digits: Int) -> String {
        var rest = seconds % 86_400
        if rest < 0 { rest += 86_400 }
        let hour = rest / 3600
        let minute = rest % 3600 / 60
        let second = rest % 60
        var text = String(format: "%02d:%02d:%02d", Int(hour), Int(minute), Int(second))
        if digits > 0 {
            let fractionText = String(fraction)
            text += "." + String(repeating: "0", count: max(0, digits - fractionText.count)) + fractionText
        }
        return text
    }
}
