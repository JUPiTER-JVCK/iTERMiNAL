import Foundation

/// One field of a file's structure: a name, the bytes it covers, and what they say.
///
/// A parser turns a file into a tree of these, and the Structure outlook shows the
/// tree beside the dump: click a field and its bytes are selected; select bytes and
/// the field that holds them lights up. So every node is a run of the file, and the
/// whole job of a parser is to be right about which run.
///
/// Foundation only, like the parsers, so CI checks them.
struct FieldNode: Identifiable {
    enum Kind: String, Equatable {
        /// A group of other fields: a header, a chunk, a packet.
        case container
        case integer
        case text
        case bytes
        /// Bits with meanings: the flags of a TCP segment.
        case flags
        /// A signature that says what the file is.
        case magic
        case checksum
        /// A network or hardware address.
        case address
        case time
        case padding
        /// Something wrong with the file here: cut off, out of range, not what it should be.
        case problem
    }

    /// How a node holds its children.
    enum Children {
        case none
        case list([FieldNode])
        /// Worked out when first looked at. A capture of a million packets does not
        /// have every packet's headers made when it is opened; each packet is
        /// dissected when someone opens it.
        case deferred(DeferredChildren)
    }

    /// Stable across a re-parse of the same file, so what is expanded stays expanded:
    /// built from the path to the field, never from a counter that could shift.
    let id: String
    var name: String
    var offset: Int64
    var length: Int64
    var kind: Kind
    /// What the bytes say, in words: "1460", "10.0.0.1", "SYN, ACK".
    var value: String?
    /// What to know about it: why it has this value, what is wrong with it.
    var note: String?
    var children: Children

    init(id: String, name: String, offset: Int64, length: Int64, kind: Kind = .container,
         value: String? = nil, note: String? = nil, children: Children = .none) {
        self.id = id
        self.name = name
        self.offset = offset
        self.length = max(0, length)
        self.kind = kind
        self.value = value
        self.note = note
        self.children = children
    }

    /// One past the last byte.
    var end: Int64 { offset + length }

    /// The last byte it covers; a field with no bytes is at its offset.
    var lastByte: Int64 { max(offset, offset + length - 1) }

    var isExpandable: Bool {
        switch children {
        case .none: return false
        case .list(let list): return !list.isEmpty
        case .deferred: return true
        }
    }

    /// The children, made now if they were being kept for later.
    func resolvedChildren() -> [FieldNode] {
        switch children {
        case .none: return []
        case .list(let list): return list
        case .deferred(let deferred): return deferred.nodes
        }
    }
}

/// Children that are made the first time they are asked for, and kept.
final class DeferredChildren {
    private let make: () -> [FieldNode]
    private var made: [FieldNode]?
    private let lock = NSLock()

    init(_ make: @escaping () -> [FieldNode]) {
        self.make = make
    }

    var nodes: [FieldNode] {
        lock.lock()
        defer { lock.unlock() }
        if let made { return made }
        let fresh = make()
        made = fresh
        return fresh
    }
}

extension FieldNode {
    /// The nodes, outermost first, that hold the byte at `offset`; none if no field does.
    /// Looks inside deferred children on the way, so a byte inside a packet finds
    /// the packet's own field, but only that packet is dissected.
    static func chain(containing offset: Int64, in roots: [FieldNode], maxDepth: Int = 64) -> [FieldNode] {
        var chain: [FieldNode] = []
        var level = roots
        while chain.count < maxDepth, let hit = node(containing: offset, among: level) {
            chain.append(hit)
            level = hit.resolvedChildren()
            if level.isEmpty { break }
        }
        return chain
    }

    /// The node among `siblings` that holds the byte at `offset`. Siblings are in file
    /// order, which is what lets a million packets be searched in twenty steps; a few
    /// that overlap (two fields sharing a byte) are looked through.
    static func node(containing offset: Int64, among siblings: [FieldNode]) -> FieldNode? {
        index(containing: offset, among: siblings).map { siblings[$0] }
    }
}
