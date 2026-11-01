import Foundation

/// A reader for MaxMind DB (`.mmdb`) files — the format IPinfo Lite, MaxMind
/// GeoLite2 and DB-IP all publish. Foundation only.
///
/// The file is whatever the person chose, so it is treated as untrusted:
/// every read is bounds-checked, nesting is capped, and anything that does
/// not add up gives nil rather than a crash.
final class MMDBReader {
    private let data: Data
    private let nodeCount: Int
    private let recordSize: Int
    private let nodeByteSize: Int
    private let treeSize: Int
    private let dataStart: Int
    private let isIPv6: Bool
    /// Where an IPv4 address starts in an IPv6 tree (`::/96`), found once.
    private lazy var ipv4Start: Int? = {
        guard isIPv6 else { return 0 }
        var node = 0
        for _ in 0..<96 {
            if node >= nodeCount { break }
            guard let next = record(node, bit: 0) else { return nil }
            node = next
        }
        return node
    }()

    private static let marker = Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
    private static let maxDepth = 16
    private static let maxEntries = 4096

    /// Opens and checks the file's metadata. Nil if it is not an MMDB file.
    init?(url: URL) {
        guard let mapped = try? Data(contentsOf: url, options: .alwaysMapped),
              mapped.count > 32 else { return nil }
        data = mapped
        // The metadata is at the end of the file, after the last marker.
        guard let range = mapped.range(of: Self.marker, options: .backwards) else { return nil }
        var offset = range.upperBound
        guard let metadata = Self.decode(mapped, &offset, base: range.upperBound, depth: 0) as? [String: Any],
              let nodes = metadata["node_count"] as? UInt64,
              let size = metadata["record_size"] as? UInt64,
              let version = metadata["ip_version"] as? UInt64,
              [24, 28, 32].contains(Int(size)), version == 4 || version == 6,
              nodes < 1 << 30 else { return nil }
        nodeCount = Int(nodes)
        recordSize = Int(size)
        nodeByteSize = recordSize / 4
        treeSize = nodeCount * nodeByteSize
        dataStart = treeSize + 16
        isIPv6 = version == 6
        guard dataStart <= range.lowerBound else { return nil }
    }

    /// The record stored for `address`, or nil when the file has none.
    func lookup(_ address: String) -> [String: Any]? {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bits: [UInt8]
        var node: Int
        if inet_pton(AF_INET, address, &v4) == 1 {
            bits = withUnsafeBytes(of: &v4) { Array($0) }
            guard let start = ipv4Start else { return nil }
            node = start
        } else if inet_pton(AF_INET6, address, &v6) == 1 {
            guard isIPv6 else { return nil }
            bits = withUnsafeBytes(of: &v6) { Array($0) }
            node = 0
        } else {
            return nil
        }

        for index in 0..<(bits.count * 8) {
            if node >= nodeCount { break }
            let bit = Int(bits[index / 8] >> (7 - UInt8(index % 8))) & 1
            guard let next = record(node, bit: bit) else { return nil }
            node = next
        }
        guard node > nodeCount else { return nil }
        var offset = node - nodeCount - 16 + dataStart
        return Self.decode(data, &offset, base: dataStart, depth: 0) as? [String: Any]
    }

    // MARK: Search tree

    private func record(_ node: Int, bit: Int) -> Int? {
        let base = node * nodeByteSize
        switch recordSize {
        case 24:
            return Self.uint(data, base + bit * 3, 3)
        case 28:
            guard let middle = Self.uint(data, base + 3, 1) else { return nil }
            if bit == 0 {
                guard let low = Self.uint(data, base, 3) else { return nil }
                return ((middle & 0xF0) << 20) | low
            }
            guard let low = Self.uint(data, base + 4, 3) else { return nil }
            return ((middle & 0x0F) << 24) | low
        default:
            return Self.uint(data, base + bit * 4, 4)
        }
    }

    // MARK: Data section

    private static func uint(_ data: Data, _ offset: Int, _ count: Int) -> Int? {
        guard offset >= 0, count >= 0, count <= 8, offset + count <= data.count else { return nil }
        var value = 0
        for index in 0..<count { value = (value << 8) | Int(data[offset + index]) }
        return value
    }

    /// Decodes one value at `offset` and moves `offset` past it. Pointers are
    /// counted from `base`, the start of the data section.
    private static func decode(_ data: Data, _ offset: inout Int, base: Int, depth: Int) -> Any? {
        guard depth < maxDepth, let control = uint(data, offset, 1) else { return nil }
        offset += 1
        var type = control >> 5

        if type == 1 {
            let size = (control >> 3) & 3
            let high = control & 7
            let value: Int
            if size == 3 {
                guard let read = uint(data, offset, 4) else { return nil }
                value = read
                offset += 4
            } else {
                guard let read = uint(data, offset, size + 1) else { return nil }
                value = ((high << (8 * (size + 1))) | read) + [0, 2048, 526_336][size]
                offset += size + 1
            }
            var target = base + value
            return decode(data, &target, base: base, depth: depth + 1)
        }

        if type == 0 {
            guard let extended = uint(data, offset, 1) else { return nil }
            type = 7 + extended
            offset += 1
        }

        var size = control & 0x1F
        if size == 29 {
            guard let extra = uint(data, offset, 1) else { return nil }
            size = 29 + extra
            offset += 1
        } else if size == 30 {
            guard let extra = uint(data, offset, 2) else { return nil }
            size = 285 + extra
            offset += 2
        } else if size == 31 {
            guard let extra = uint(data, offset, 3) else { return nil }
            size = 65_821 + extra
            offset += 3
        }

        switch type {
        case 2: // UTF-8 string
            guard offset + size <= data.count else { return nil }
            let text = String(decoding: data[offset..<offset + size], as: UTF8.self)
            offset += size
            return text
        case 3: // double
            guard size == 8, let bits = uint(data, offset, 8) else { return nil }
            offset += 8
            return Double(bitPattern: UInt64(bitPattern: Int64(bits)))
        case 4: // bytes
            guard offset + size <= data.count else { return nil }
            let bytes = data[offset..<offset + size]
            offset += size
            return Data(bytes)
        case 5, 6, 9: // unsigned integers
            guard size <= 8, let value = uint(data, offset, size) else { return nil }
            offset += size
            return UInt64(bitPattern: Int64(value))
        case 7: // map
            guard size <= maxEntries else { return nil }
            var map: [String: Any] = [:]
            for _ in 0..<size {
                guard let key = decode(data, &offset, base: base, depth: depth + 1) as? String,
                      let value = decode(data, &offset, base: base, depth: depth + 1) else { return nil }
                map[key] = value
            }
            return map
        case 8: // int32
            guard size <= 4, let value = uint(data, offset, size) else { return nil }
            offset += size
            return Int32(truncatingIfNeeded: value)
        case 10: // uint128 — not needed here; skipped
            guard offset + size <= data.count else { return nil }
            offset += size
            return Data()
        case 11: // array
            guard size <= maxEntries else { return nil }
            var array: [Any] = []
            for _ in 0..<size {
                guard let value = decode(data, &offset, base: base, depth: depth + 1) else { return nil }
                array.append(value)
            }
            return array
        case 14: // boolean: the size is the value
            return size != 0
        case 15: // float
            guard size == 4, let bits = uint(data, offset, 4) else { return nil }
            offset += 4
            return Double(Float(bitPattern: UInt32(bits)))
        default:
            return nil
        }
    }
}
