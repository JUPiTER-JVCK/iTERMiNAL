import SwiftUI
import AppKit

/// How the bytes are shown: written in a base, as the bits in them, or beside the fields
/// the file's format says they make up.
enum BytesMode: String, CaseIterable, Hashable {
    case hex, bits, structure
}

/// Where the Structure outlook has got to with the open file.
enum StructureState {
    case idle
    case parsing
    case ready(StructureResult)
}

/// A request to scroll the Structure tree to a field.
struct StructureScrollRequest: Equatable {
    let id = UUID()
    let nodeID: String
}

/// A file the panel was asked to open and would not, and why.
struct BytesRefusal: Equatable {
    let name: String
    let why: BytesFilePolicy.Refusal

    var message: String { BytesFilePolicy.message(why, name: name) }
    var isProblem: Bool { BytesFilePolicy.isProblem(why) }
}

/// A request to bring a byte into view: from "Go to offset", or from opening a file.
/// Each is its own, even for the same offset, so asking again scrolls again.
struct BytesRevealRequest: Equatable {
    let id = UUID()
    let offset: Int64
    /// Put it in the middle if it is out of sight, rather than at the nearest edge.
    let centered: Bool
}

/// The Bytes panel's state: the file being looked at, what is selected in it, and
/// how it is shown.
///
/// Held by `WorkspaceStore` for as long as the app runs, like the Notes and the
/// HTTP client's, so closing the panel puts it away without letting go of the file.
/// Not `@MainActor`, for the same reason `HTTPClientModel` is not: it is read from
/// code that is not.
///
/// Nothing is read until a file is opened, and opening one reads none of it: the
/// grid asks for the few rows it is drawing.
final class BytesViewerModel: ObservableObject {
    /// The file shown, or nil when there is none.
    @Published private(set) var fileURL: URL?
    /// Its bytes, with any edits over them. A value, so a change to it publishes.
    @Published private(set) var buffer: ByteEditBuffer?
    /// What the last file offered to the panel was refused for. Shown in place of
    /// the empty state, or over a file that is open without closing it.
    @Published private(set) var refusal: BytesRefusal?
    @Published private(set) var selection: ByteSelection?
    @Published private(set) var reveal: BytesRevealRequest?
    /// A line to say something to the person: a go-to that found nothing, a copy
    /// that was too big.
    @Published private(set) var notice: String?
    @Published var goToText = ""

    // MARK: Structure

    /// The file taken apart by the parser that knows its format, made in the background.
    @Published private(set) var structure: StructureState = .idle
    /// The tree as lines: what is open, and no more of a long level than has been asked for.
    @Published private(set) var structureRows: [StructureRow] = []
    /// The field that holds the cursor, shown selected in the tree.
    @Published private(set) var focusedNode: FieldNode?
    /// Set when the selection moved in the dump, so the tree follows it.
    @Published private(set) var structureScroll: StructureScrollRequest?
    private var expandedNodes: Set<String> = []
    private var rowLimits: [String: Int] = [:]
    private var parseCancellation: ParseCancellation?

    @Published var mode: BytesMode = BytesViewerModel.storedMode() {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "bytes.mode")
            if mode == .structure { followSelection(scroll: true) }
        }
    }
    /// The base of the cells in the Hex outlook; Bits is always binary.
    @Published var cellRadix: ByteRadix = BytesViewerModel.storedRadix() {
        didSet { UserDefaults.standard.set(cellRadix.rawValue, forKey: "bytes.radix") }
    }
    /// Bytes to a row; 0 fits as many as the pane has room for.
    @Published var bytesPerRow: Int = BytesViewerModel.storedInt("bytes.bytesPerRow", default: 0) {
        didSet { UserDefaults.standard.set(bytesPerRow, forKey: "bytes.bytesPerRow") }
    }
    @Published var showsText: Bool = BytesViewerModel.storedFlag("bytes.showsText", default: true) {
        didSet { UserDefaults.standard.set(showsText, forKey: "bytes.showsText") }
    }
    @Published var showsInspector: Bool = BytesViewerModel.storedFlag("bytes.showsInspector", default: true) {
        didSet { UserDefaults.standard.set(showsInspector, forKey: "bytes.showsInspector") }
    }
    @Published var endianness: Endianness = BytesViewerModel.storedEndianness() {
        didSet { UserDefaults.standard.set(endianness.rawValue, forKey: "bytes.endianness") }
    }

    // MARK: Reading the state

    var hasFile: Bool { buffer != nil }
    var fileName: String { fileURL?.lastPathComponent ?? "" }
    var length: Int64 { buffer?.length ?? 0 }

    /// The base the grid writes its cells in.
    var radix: ByteRadix { mode == .bits ? .binary : cellRadix }

    /// The bytes the inspector reads: the start of the selection, and no more than
    /// the longest text it will decode.
    func inspectedBytes() -> [UInt8] {
        guard let buffer, let selection else { return [] }
        let end = min(selection.upperBound + 1, selection.lowerBound + Int64(ByteInterpreter.maxTextBytes))
        return buffer.read(selection.lowerBound..<end)
    }

    // MARK: Opening and closing

    /// Shows `url`, or says why it cannot be shown. A file that is refused leaves
    /// the one that is open as it was.
    func open(url: URL) {
        switch FileByteSource.opening(path: url.path) {
        case .success(let source):
            buffer = ByteEditBuffer(source: source)
            fileURL = url
            refusal = nil
            notice = nil
            goToText = ""
            selection = ByteSelection(at: 0)
            reveal = BytesRevealRequest(offset: 0, centered: false)
            startStructure(source)
        case .failure(let why):
            refusal = BytesRefusal(name: url.lastPathComponent, why: why)
        }
    }

    func close() {
        parseCancellation?.cancel()
        parseCancellation = nil
        buffer = nil
        fileURL = nil
        selection = nil
        reveal = nil
        notice = nil
        refusal = nil
        goToText = ""
        structure = .idle
        structureRows = []
        focusedNode = nil
        expandedNodes = []
        rowLimits = [:]
    }

    func dismissNotice() {
        notice = nil
    }

    func dismissRefusal() {
        refusal = nil
    }

    // MARK: Selecting

    /// Selects `new`, kept inside the file. This is what the dump calls, so the tree follows.
    func select(_ new: ByteSelection?) {
        selection = new?.limited(toLength: length)
        if mode == .structure { followSelection(scroll: true) }
    }

    // MARK: Structure

    private func startStructure(_ source: ByteSource) {
        parseCancellation?.cancel()
        let token = ParseCancellation()
        parseCancellation = token
        structure = .parsing
        structureRows = []
        focusedNode = nil
        expandedNodes = []
        rowLimits = [:]
        var context = ParseContext()
        context.isCancelled = { token.isCancelled }
        let work = context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FormatRegistry.analyze(source, context: work)
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.structure = .ready(result)
                self.rebuildRows()
                if self.mode == .structure { self.followSelection(scroll: true) }
            }
        }
    }

    private func rebuildRows() {
        guard case .ready(let result) = structure else {
            structureRows = []
            return
        }
        structureRows = StructureOutline.rows(roots: result.outcome.roots, expanded: expandedNodes, limits: rowLimits)
    }

    /// Shows, in the tree, the field that holds the byte the cursor is on: opening what has to
    /// be opened, and listing a level far enough to reach it.
    private func followSelection(scroll: Bool) {
        guard case .ready(let result) = structure, let head = selection?.head else {
            focusedNode = nil
            return
        }
        let found = StructureOutline.reveal(offset: head, in: result.outcome.roots, limits: rowLimits)
        guard let focus = found.focus else {
            focusedNode = nil
            return
        }
        var changed = found.limits != rowLimits
        rowLimits = found.limits
        for id in found.open where !expandedNodes.contains(id) {
            expandedNodes.insert(id)
            changed = true
        }
        if changed { rebuildRows() }
        focusedNode = focus
        if scroll { structureScroll = StructureScrollRequest(nodeID: focus.id) }
    }

    func toggleExpansion(of node: FieldNode) {
        if expandedNodes.contains(node.id) {
            expandedNodes.remove(node.id)
        } else {
            expandedNodes.insert(node.id)
        }
        rebuildRows()
    }

    /// Lists a page more of the level under `parentID`.
    func showMore(under parentID: String) {
        rowLimits = StructureOutline.showingMore(under: parentID, limits: rowLimits)
        rebuildRows()
    }

    /// Selects the bytes of a field, from a click on it in the tree. The dump scrolls to it; the
    /// tree does not, since it is where the click was.
    func selectNode(_ node: FieldNode) {
        guard let buffer, buffer.length > 0 else { return }
        let last = buffer.length - 1
        let first = min(max(node.offset, 0), last)
        let end = min(max(node.lastByte, first), last)
        selection = ByteSelection(anchor: first, head: end)
        focusedNode = node
        reveal = BytesRevealRequest(offset: first, centered: true)
    }

    /// Goes to what is typed in the "Go to offset" field.
    func goTo() {
        guard let buffer else { return }
        switch OffsetExpression.resolve(goToText, cursor: selection?.head ?? 0, length: buffer.length) {
        case .success(let offset):
            notice = nil
            selection = ByteSelection(at: offset)
            reveal = BytesRevealRequest(offset: offset, centered: true)
            if mode == .structure { followSelection(scroll: true) }
        case .failure(let failure):
            notice = OffsetExpression.message(failure)
        }
    }

    // MARK: Copying

    /// Puts the selected bytes on the pasteboard as `format`.
    func copySelection(as format: ByteExportFormat) {
        guard let buffer, let selection else { return }
        guard selection.count <= Int64(ByteExport.maxBytes) else {
            notice = "That is more than can be copied at once: \(ByteExport.maxBytes / 1_048_576) MB. Select less."
            return
        }
        let text = ByteExport.string(buffer.read(selection.range), as: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: What was chosen last time

    private static func storedFlag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private static func storedInt(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? value
    }

    private static func storedMode() -> BytesMode {
        BytesMode(rawValue: UserDefaults.standard.string(forKey: "bytes.mode") ?? "") ?? .hex
    }

    /// Binary is the Bits outlook's, so a stored binary falls back to hex.
    private static func storedRadix() -> ByteRadix {
        let radix = ByteRadix(rawValue: UserDefaults.standard.string(forKey: "bytes.radix") ?? "") ?? .hex
        return radix == .binary ? .hex : radix
    }

    private static func storedEndianness() -> Endianness {
        Endianness(rawValue: UserDefaults.standard.string(forKey: "bytes.endianness") ?? "") ?? .little
    }
}
