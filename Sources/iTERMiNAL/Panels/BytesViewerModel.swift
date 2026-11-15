import SwiftUI
import AppKit

/// How the bytes are written: in a base, or as the bits in them.
enum BytesMode: String, CaseIterable, Hashable {
    case hex, bits
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

    @Published var mode: BytesMode = BytesViewerModel.storedMode() {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "bytes.mode") }
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
        case .failure(let why):
            refusal = BytesRefusal(name: url.lastPathComponent, why: why)
        }
    }

    func close() {
        buffer = nil
        fileURL = nil
        selection = nil
        reveal = nil
        notice = nil
        refusal = nil
        goToText = ""
    }

    func dismissNotice() {
        notice = nil
    }

    func dismissRefusal() {
        refusal = nil
    }

    // MARK: Selecting

    /// Selects `new`, kept inside the file.
    func select(_ new: ByteSelection?) {
        selection = new?.limited(toLength: length)
    }

    /// Goes to what is typed in the "Go to offset" field.
    func goTo() {
        guard let buffer else { return }
        switch OffsetExpression.resolve(goToText, cursor: selection?.head ?? 0, length: buffer.length) {
        case .success(let offset):
            notice = nil
            selection = ByteSelection(at: offset)
            reveal = BytesRevealRequest(offset: offset, centered: true)
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
