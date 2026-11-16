import Foundation

/// A classic pcap capture file (tcpdump, libpcap): a 24-byte global header, then each
/// captured packet as a 16-byte record header and its bytes.
///
/// The file is listed record by record, each with a one-line summary worked out from the
/// first bytes of its packet. What is inside a packet is made when the packet is opened, so
/// a capture of a million packets is a million small nodes and not a hundred million fields.
/// Only the first `maxRecords` are listed; the rest of the file is still in the dump.
enum PcapParser: FormatParser {
    static let identity = FormatIdentity(id: "pcap", name: "a packet capture (pcap)", detail: "libpcap file format", hasParser: true)

    /// The byte order and timestamp unit the magic number says.
    struct Variant {
        let endianness: Endianness
        let nanoseconds: Bool

        var description: String {
            (endianness == .little ? "little-endian" : "big-endian") + ", " + (nanoseconds ? "nanosecond" : "microsecond") + " timestamps"
        }
    }

    static func variant(of head: [UInt8]) -> Variant? {
        guard head.count >= 4 else { return nil }
        switch (head[0], head[1], head[2], head[3]) {
        case (0xD4, 0xC3, 0xB2, 0xA1): return Variant(endianness: .little, nanoseconds: false)
        case (0xA1, 0xB2, 0xC3, 0xD4): return Variant(endianness: .big, nanoseconds: false)
        case (0x4D, 0x3C, 0xB2, 0xA1): return Variant(endianness: .little, nanoseconds: true)
        case (0xA1, 0xB2, 0x3C, 0x4D): return Variant(endianness: .big, nanoseconds: true)
        default: return nil
        }
    }

    static func matches(head: [UInt8], length: Int64) -> Bool {
        variant(of: head) != nil
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let head = ByteWindow(source: source, at: 0, count: 24)
        guard let variant = variant(of: head.bytes) else { return outcome }
        let endianness = variant.endianness
        let nanoseconds = variant.nanoseconds

        var linkType: UInt32 = 0
        var headerList = FieldList(idPrefix: "pcap", window: head, endianness: endianness)
        headerList.group("Global header", at: 0, length: 24) { f in
            f.uint("Magic", at: 0, size: 4, kind: .magic, value: { value in
                FieldText.hexNumber(value, size: 4) + " · " + variant.description
            }, note: { _ in "Read the same way round, 0xA1B2C3D4 means microseconds and 0xA1B23C4D nanoseconds. Which way the bytes are written says the file's byte order." })
            f.uint("Version major", at: 4, size: 2)
            f.uint("Version minor", at: 6, size: 2)
            f.uint("Time zone offset", at: 8, size: 4, value: { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) seconds" },
                   note: { _ in "Always 0 in practice: the timestamps are UTC." })
            f.uint("Timestamp accuracy", at: 12, size: 4, note: { _ in "Always 0 in practice." })
            f.uint("Snap length", at: 16, size: 4, value: { FieldText.bytes(Int64($0)) },
                   note: { _ in "Packets longer than this were cut when they were captured." })
            if let raw = f.uint("Link type", at: 20, size: 4, value: { PacketNames.linkType(UInt32(truncatingIfNeeded: $0 & 0x0FFF_FFFF)) },
                                note: { $0 >> 28 != 0 ? "The top four bits carry the length of a frame check sequence kept on the end of each packet." : "What the first bytes of every packet are." }) {
                linkType = UInt32(truncatingIfNeeded: raw & 0x0FFF_FFFF)
            }
        }
        outcome.roots.append(contentsOf: headerList.nodes)
        guard !headerList.truncated else {
            outcome.problems.append("The file ends inside the 24-byte global header.")
            outcome.summary = "pcap capture, cut off in its header"
            return outcome
        }

        let digits = nanoseconds ? 9 : 6
        var position: Int64 = 24
        var number = 0
        var problems: [String] = []

        while position < total {
            if number >= context.maxRecords {
                outcome.listingLimit = "The first \(context.maxRecords) packets are listed; the rest of the file is in the dump."
                outcome.roots.append(FieldNode(
                    id: "pcap/more", name: "More packets", offset: position, length: total - position, kind: .bytes,
                    value: "not listed", note: "Listing stops after \(context.maxRecords) packets."))
                break
            }
            if context.isCancelled() {
                problems.append("Stopped before the end of the file.")
                break
            }
            // The record header and the start of the packet, in one read.
            let peek = ByteWindow(source: source, at: position, count: 16 + 128)
            guard let seconds = peek.u32(position, endianness), let fraction = peek.u32(position + 4, endianness),
                  let included = peek.u32(position + 8, endianness), let original = peek.u32(position + 12, endianness) else {
                let left = total - position
                outcome.roots.append(FieldNode(
                    id: "pcap/cut", name: "Cut off", offset: position, length: left, kind: .problem,
                    value: "\(FieldText.bytes(left)) left",
                    note: "A packet record starts with 16 bytes and the file ends before they do."))
                problems.append("The file ends inside a packet record header, at \(FieldText.hexNumber(UInt64(position), size: 1)).")
                break
            }
            number += 1
            let start = position
            let dataStart = position + 16
            let promised = Int64(included)
            let available = max(0, min(promised, total - dataStart))
            let isCut = promised > total - dataStart
            let summaryBytes = Array(peek.bytes.dropFirst(16).prefix(Int(min(available, 128))))
            let summary = PacketDissector.dissect(
                linkType: linkType, window: ByteWindow(base: dataStart, bytes: summaryBytes), idPrefix: "", recording: false).summary
            let clock = PacketNames.clock(seconds: Int64(seconds), fraction: UInt64(fraction), digits: digits)
            let id = "pcap/pkt\(number)"

            var note = "\(FieldText.bytes(promised)) captured"
            if original > included { note += " of \(original): cut to the snap length when it was captured" }
            if isCut { note = "The record says \(FieldText.bytes(promised)) follow, and the file ends after \(FieldText.bytes(available))." }
            if isCut {
                problems.append("Packet \(number) is cut off: the file ends after \(FieldText.bytes(available)) of its \(FieldText.bytes(promised)).")
            }

            let capturedLinkType = linkType
            outcome.roots.append(FieldNode(
                id: id, name: "Packet \(number)", offset: start, length: 16 + available, kind: isCut ? .problem : .container,
                value: "\(clock) · \(promised) B · \(summary)", note: note,
                children: .deferred(DeferredChildren {
                    recordChildren(id: id, source: source, position: start, endianness: endianness, nanoseconds: nanoseconds,
                                   linkType: capturedLinkType, included: included, dataLength: available, summary: summary)
                })))
            position += 16 + available
            if isCut { break }
        }

        outcome.problems = Array(problems.prefix(20))
        let listed = outcome.roots.filter { $0.id.hasPrefix("pcap/pkt") }.count
        let linkName = PacketNames.linkTypes[linkType] ?? "link type \(linkType)"
        outcome.summary = "pcap capture, \(linkName), \(listed) \(listed == 1 ? "packet" : "packets")"
        return outcome
    }

    /// What is inside one packet record: its header, and its bytes taken apart.
    private static func recordChildren(id: String, source: ByteSource, position: Int64, endianness: Endianness, nanoseconds: Bool,
                                       linkType: UInt32, included: UInt32, dataLength: Int64, summary: String) -> [FieldNode] {
        var list = FieldList(idPrefix: id, window: ByteWindow(source: source, at: position, count: 16), endianness: endianness)
        list.group("Record header", at: position, length: 16) { f in
            f.uint("Timestamp seconds", at: position, size: 4, kind: .time, value: {
                "\($0) · " + ByteInterpreter.utcString(unixSeconds: Int64($0))
            })
            f.uint("Timestamp fraction", at: position + 4, size: 4, kind: .time, value: { "\($0) " + (nanoseconds ? "nanoseconds" : "microseconds") })
            f.uint("Captured length", at: position + 8, size: 4, value: { FieldText.bytes(Int64($0)) },
                   note: { _ in "How many bytes of the packet are in this file." })
            f.uint("Original length", at: position + 12, size: 4, value: { FieldText.bytes(Int64($0)) },
                   note: { $0 > UInt64(included) ? "The packet was \(FieldText.bytes(Int64($0))) on the wire and was cut to \(FieldText.bytes(Int64(included))) when it was captured." : "As long as it was on the wire." })
        }
        var nodes = list.nodes
        let dataStart = position + 16
        if dataLength == 0 {
            nodes.append(FieldNode(id: id + "/packet", name: "Packet data", offset: dataStart, length: 0, kind: .bytes, value: "no bytes captured"))
            return nodes
        }
        let window = ByteWindow(source: source, at: dataStart, count: Int(min(dataLength, 262_144)))
        let dissected = PacketDissector.dissect(linkType: linkType, window: window, idPrefix: id + "/packet")
        nodes.append(FieldNode(id: id + "/packet", name: "Packet data", offset: dataStart, length: dataLength, kind: .container,
                               value: summary, children: dissected.nodes.isEmpty ? .none : .list(dissected.nodes)))
        return nodes
    }
}
