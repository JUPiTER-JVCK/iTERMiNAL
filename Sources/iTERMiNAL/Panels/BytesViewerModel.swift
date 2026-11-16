import SwiftUI
import AppKit

/// How the bytes are shown: written in a base, as the bits in them, beside the fields
/// the file's format says they make up, or as a map of what kind of bytes are where.
enum BytesMode: String, CaseIterable, Hashable {
    case hex, bits, structure, map
}

/// Where the Structure outlook has got to with the open file.
enum StructureState {
    case idle
    case parsing
    case ready(StructureResult)
}

/// Where the Map outlook has got to with the open file.
enum MapState {
    case idle
    /// Reading the file, this far along: 0 to 1.
    case analysing(Double)
    case ready(ByteMapResult)
}

/// What the Map outlook shows: what the pass over the file found, and the picture made from it,
/// in each of the ways it can be coloured.
struct ByteMapResult {
    let analysis: ByteMapAnalysis
    let byteClassImage: CGImage?
    let entropyImage: CGImage?

    func image(for coloring: ByteMapColoring) -> CGImage? {
        switch coloring {
        case .byteClass: return byteClassImage
        case .entropy: return entropyImage
        }
    }
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
    @Published private(set) var selection: ByteSelection? {
        didSet {
            // A half-typed byte belongs to where the cursor was when its first digit went in.
            if selection != typingCursor { typing.forget() }
        }
    }
    @Published private(set) var reveal: BytesRevealRequest?
    /// A line to say something to the person: a go-to that found nothing, a copy
    /// that was too big.
    @Published private(set) var notice: String?
    @Published var goToText = ""

    // MARK: Editing

    /// Whether the file can be changed and saved: it can be written, and so can the folder it is in, where a
    /// save makes its new file before swapping it in.
    @Published private(set) var isWritable = false
    /// Why not, when it cannot: for the Read-only badge, and for a key typed all the same.
    @Published private(set) var readOnlyReason: String?
    /// Overwrite changes bytes where they are; Insert puts bytes in and takes them out, and moves what follows.
    @Published var editMode: ByteTyping.Mode = .overwrite {
        didSet {
            typing.mode = editMode
            typing.forget()
        }
    }
    /// Leave the file as it was beside the new one, as `name.bak`, when saving.
    @Published var keepsBackup: Bool = BytesViewerModel.storedFlag("bytes.keepsBackup", default: true) {
        didSet { UserDefaults.standard.set(keepsBackup, forKey: "bytes.keepsBackup") }
    }
    @Published private(set) var isSaving = false
    /// What the last save did, until the next edit.
    @Published private(set) var savedNote: String?
    private var typing = ByteTyping()
    /// Where typing left the cursor, so that moving it somewhere else can be told from typing.
    private var typingCursor: ByteSelection?
    private var reparseWork: DispatchWorkItem?

    var isDirty: Bool { buffer?.isDirty ?? false }
    var canUndo: Bool { buffer?.canUndo ?? false }
    var canRedo: Bool { buffer?.canRedo ?? false }

    // MARK: Find

    /// What the find bar looks for.
    enum FindKind: String, CaseIterable {
        case hex
        case text
    }

    @Published private(set) var showsFind = false
    /// What is typed in the find bar: bytes as hex ("DE AD ?? EF") or text, by `findKind`.
    @Published var findText = "" {
        didSet {
            guard findText != oldValue else { return }
            findStatus = nil
            lastMatch = nil
        }
    }
    @Published var findKind: FindKind = BytesViewerModel.storedFindKind() {
        didSet {
            UserDefaults.standard.set(findKind.rawValue, forKey: "bytes.findKind")
            findStatus = nil
            lastMatch = nil
        }
    }
    /// For text: A to Z match in either case.
    @Published var findIgnoresCase: Bool = BytesViewerModel.storedFlag("bytes.findIgnoresCase", default: true) {
        didSet { UserDefaults.standard.set(findIgnoresCase, forKey: "bytes.findIgnoresCase") }
    }
    /// For text: the bytes it is looked for as.
    @Published var findEncoding: SearchPattern.TextEncoding = BytesViewerModel.storedFindEncoding() {
        didSet {
            UserDefaults.standard.set(findEncoding.rawValue, forKey: "bytes.findEncoding")
            findStatus = nil
            lastMatch = nil
        }
    }
    /// What the last search found, or why it did not.
    @Published private(set) var findStatus: String?
    /// How far through the file a search that is under way has got, from 0 to 1.
    @Published private(set) var findProgress: Double?
    private var findCancellation: ParseCancellation?
    /// The bytes the last search found, so that "next" goes past them and not onto them again.
    private var lastMatch: Range<Int64>?

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

    // MARK: Map

    /// The pass over the file that the Map outlook is made from. It reads a lot of the file, so
    /// it is not begun until the outlook is looked at.
    @Published private(set) var map: MapState = .idle
    /// How the cells of the map are coloured.
    @Published var mapColoring: ByteMapColoring = BytesViewerModel.storedColoring() {
        didSet { UserDefaults.standard.set(mapColoring.rawValue, forKey: "bytes.mapColoring") }
    }
    private var mapCancellation: ParseCancellation?
    /// The file as it was opened, which the map's pass reads a copy of.
    private var openedSource: FileByteSource?

    @Published var mode: BytesMode = BytesViewerModel.storedMode() {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "bytes.mode")
            if mode == .structure { followSelection(scroll: true) }
            if mode == .map { startMapIfNeeded() }
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
            savedNote = nil
            goToText = ""
            readOnlyReason = BytesViewerModel.writeRefusal(url)
            isWritable = readOnlyReason == nil
            typing = ByteTyping()
            typing.mode = editMode
            typingCursor = nil
            reparseWork?.cancel()
            cancelFind()
            findStatus = nil
            lastMatch = nil
            selection = ByteSelection(at: 0)
            reveal = BytesRevealRequest(offset: 0, centered: false)
            startStructure(source)
            openedSource = source
            resetMap()
            if mode == .map { startMapIfNeeded() }
        case .failure(let why):
            refusal = BytesRefusal(name: url.lastPathComponent, why: why)
        }
    }

    func close() {
        parseCancellation?.cancel()
        parseCancellation = nil
        openedSource = nil
        resetMap()
        buffer = nil
        fileURL = nil
        selection = nil
        reveal = nil
        notice = nil
        refusal = nil
        savedNote = nil
        isWritable = false
        readOnlyReason = nil
        reparseWork?.cancel()
        goToText = ""
        cancelFind()
        findStatus = nil
        lastMatch = nil
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

    /// Takes the file apart again after an edit or a save: what is open in the tree stays open, and the old
    /// tree stays up until the new one is ready.
    private func startStructure(_ source: ByteSource, keepingView: Bool = false) {
        parseCancellation?.cancel()
        let token = ParseCancellation()
        parseCancellation = token
        if !keepingView {
            structure = .parsing
            structureRows = []
            focusedNode = nil
            expandedNodes = []
            rowLimits = [:]
        }
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

    // MARK: Map

    /// Stops any pass over the file, and forgets what it found.
    private func resetMap() {
        mapCancellation?.cancel()
        mapCancellation = nil
        map = .idle
    }

    /// Begins the pass over the file if the map has not been made, or is not being. It reads the
    /// file as it is on disk, which is all the panel shows until it can edit; once it can, an edit
    /// will have to call `resetMap()` so the map is made again.
    private func startMapIfNeeded() {
        guard case .idle = map, let shared = openedSource else { return }
        let token = ParseCancellation()
        mapCancellation = token
        map = .analysing(0)
        // With edits over the file, the map is of what the dump shows, not of what is on disk.
        let edited: ByteSource? = buffer.flatMap { $0.isDirty ? EditedBytesSource($0) : nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The pass reads through a source of its own, so that its reads do not push out of the
            // cache the pages the grid is showing. If the file is not the one that was opened (it
            // was replaced, or is gone), the shared source, which still holds what the grid shows,
            // is read instead.
            var source: ByteSource = shared
            if let edited {
                source = edited
            } else if case .success(let own) = FileByteSource.opening(path: shared.path), own.identity == shared.identity {
                source = own
            }
            var lastReport = DispatchTime.now().uptimeNanoseconds
            let analysis = ByteMapAnalyzer.analyze(
                source,
                isCancelled: { token.isCancelled },
                progress: { fraction in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now - lastReport > 80_000_000 else { return }
                    lastReport = now
                    DispatchQueue.main.async {
                        guard let self, !token.isCancelled, case .analysing = self.map else { return }
                        self.map = .analysing(fraction)
                    }
                }
            )
            guard let analysis, !token.isCancelled else { return }
            let result = ByteMapResult(
                analysis: analysis,
                byteClassImage: ByteMapImage.make(analysis, coloring: .byteClass),
                entropyImage: ByteMapImage.make(analysis, coloring: .entropy)
            )
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.map = .ready(result)
            }
        }
    }

    /// Puts the cursor on the byte at `offset`, from a click on the map or the graph, and brings
    /// it to the middle of the dump.
    func moveCursor(to offset: Int64) {
        guard let buffer, buffer.length > 0 else { return }
        let target = min(max(offset, 0), buffer.length - 1)
        selection = ByteSelection(at: target)
        reveal = BytesRevealRequest(offset: target, centered: true)
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

    // MARK: Editing

    /// Why the person cannot change this file, or nil if they can.
    private static func writeRefusal(_ url: URL) -> String? {
        let manager = FileManager.default
        let name = url.lastPathComponent
        guard manager.isWritableFile(atPath: url.path) else {
            return "\(name) is read-only, so it can be looked at but not changed."
        }
        // A save makes its new file beside the original before swapping it in.
        guard manager.isWritableFile(atPath: url.resolvingSymlinksInPath().deletingLastPathComponent().path) else {
            return "The folder \(name) is in cannot be written to, and a save makes its new file there, so it can be looked at but not changed."
        }
        if let names = ByteFileSaver.nameCount(ofFileAt: url.path), names > 1 {
            return "\(name) has \(names - 1) other \(names == 2 ? "name" : "names") (hard links). A save would leave \(names == 2 ? "it" : "them") with the old bytes, so it can be looked at but not changed."
        }
        return nil
    }

    /// Types one hex digit (0 to 15) at the cursor.
    func typeHexDigit(_ digit: UInt8) {
        perform { rules, buffer, selection in try rules.hexDigit(digit, in: &buffer, at: selection) }
    }

    /// Types characters in the text column.
    func typeText(_ text: String) {
        perform { rules, buffer, selection in try rules.text(text, in: &buffer, at: selection) }
    }

    func deleteBackward() {
        perform { rules, buffer, selection in try rules.deleteBackward(in: &buffer, at: selection) }
    }

    func deleteForward() {
        perform { rules, buffer, selection in try rules.deleteForward(in: &buffer, at: selection) }
    }

    /// Sets every selected byte to `value`.
    func fillSelection(with value: UInt8) {
        perform { rules, buffer, selection in
            try rules.fill(value, in: &buffer, at: selection)
            return selection
        }
    }

    /// Puts the cursor on the last byte, so that typing adds to the end of the file.
    func beginAppending() {
        guard isWritable, let buffer else { return }
        editMode = .insert
        let target = typing.beginAppending(to: buffer)
        typingCursor = target
        selection = target
        if let head = target?.head { reveal = BytesRevealRequest(offset: head, centered: false) }
    }

    /// Runs one edit on a copy of the buffer, and keeps the copy only if the edit worked.
    private func perform(_ change: (inout ByteTyping, inout ByteEditBuffer, ByteSelection?) throws -> ByteSelection?) {
        guard var working = buffer, !isSaving else { return }
        guard isWritable else {
            notice = readOnlyReason ?? "\(fileName) cannot be changed."
            return
        }
        var rules = typing
        let next: ByteSelection?
        do {
            next = try change(&rules, &working, selection)
        } catch let failure as ByteTyping.Failure {
            typing = rules
            switch failure {
            case .needsInsertMode:
                notice = "Delete takes bytes out, which moves everything after them. Choose Insert first."
            case .edit(let error):
                notice = BytesViewerModel.message(for: error)
            case .nothing:
                break
            }
            return
        } catch {
            return
        }
        typing = rules
        // A key that changed nothing (Backspace at the start, a character that is no byte) is not an edit:
        // the map, the tree and the search's place stay as they are.
        let changed = working.revision != buffer?.revision
        if changed { buffer = working }
        typingCursor = next?.limited(toLength: working.length)
        selection = typingCursor
        if let head = selection?.head { reveal = BytesRevealRequest(offset: head, centered: false) }
        if changed { editsChanged() }
    }

    private static func message(for error: ByteEditError) -> String {
        switch error {
        case .tooManyPieces:
            return "That is more separate edits than can be kept track of. Save, and carry on."
        case .tooMuchAddedData:
            return "That is more new bytes than can be held at once. Save, and carry on."
        case .unreadable(let offset):
            return "The file could not be read at \(offset): it changed while it was open."
        }
    }

    func undo() { stepHistory { $0.undo() } }
    func redo() { stepHistory { $0.redo() } }

    private func stepHistory(_ step: (inout ByteEditBuffer) -> Bool) {
        guard var working = buffer, !isSaving, step(&working) else { return }
        buffer = working
        typing.forget()
        typingCursor = nil
        if working.length > 0 {
            selection = selection?.limited(toLength: working.length) ?? ByteSelection(at: 0)
        } else {
            selection = nil
        }
        if let head = selection?.head { reveal = BytesRevealRequest(offset: head, centered: false) }
        editsChanged()
    }

    /// What an edit puts out of date: the search's place, the map, and the tree of fields, which is made again
    /// once the typing stops.
    private func editsChanged() {
        savedNote = nil
        // A search under way is of the bytes as they were: what it found could be somewhere else now, or gone.
        cancelFind()
        lastMatch = nil
        findStatus = nil
        // The map is of the bytes as they were too. It is made again with the tree, when the typing stops,
        // and not once for every key.
        resetMap()
        reparseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let buffer = self.buffer else { return }
            self.startStructure(EditedBytesSource(buffer), keepingView: true)
            if self.mode == .map { self.startMapIfNeeded() }
        }
        reparseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Saving

    /// Writes the edits into the file, in the background, safely: see `ByteFileSaver`. `completion` is told, on the main
    /// queue, whether the file is now as the dump shows it.
    func save(then completion: ((Bool) -> Void)? = nil) {
        guard let buffer, let source = openedSource, buffer.isDirty, !isSaving else {
            completion?(!isDirty)
            return
        }
        isSaving = true
        notice = nil
        let keeps = keepsBackup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<ByteFileSaver.Method, ByteFileSaver.Failure>
            do {
                outcome = .success(try ByteFileSaver.save(buffer, over: source, keepsBackup: keeps))
            } catch let failure as ByteFileSaver.Failure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(.cannotWrite(error.localizedDescription))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                // If another file was opened, or this one closed, while the save ran, the save is still done (or not),
                // but what is shown now is not what was saved, and is left alone.
                let stillOpen = self.openedSource === source
                switch outcome {
                case .success(let method):
                    if stillOpen { self.didSave(method: method) }
                    completion?(true)
                case .failure(let failure):
                    if stillOpen { self.notice = ByteFileSaver.message(failure, name: self.fileName) }
                    completion?(false)
                }
            }
        }
    }

    /// Saves now, on this thread, for a quit that is waiting on it. Nil when it worked, else why not.
    func saveNow() -> String? {
        guard let buffer, let source = openedSource, buffer.isDirty else { return nil }
        // Two saves of one file at once would each take the other's work for someone else's.
        guard !isSaving else { return "\(fileName) is still being saved. Try again in a moment." }
        do {
            try ByteFileSaver.save(buffer, over: source, keepsBackup: keepsBackup)
            return nil
        } catch let failure as ByteFileSaver.Failure {
            return ByteFileSaver.message(failure, name: fileName)
        } catch {
            return error.localizedDescription
        }
    }

    /// The file is changed on disk; the panel now shows it as it is, from a new source, and the steps of undo are let go.
    private func didSave(method: ByteFileSaver.Method) {
        guard let url = fileURL else { return }
        switch FileByteSource.opening(path: url.path) {
        case .success(let fresh):
            buffer = ByteEditBuffer(source: fresh)
            openedSource = fresh
            typing = ByteTyping()
            typing.mode = editMode
            typingCursor = nil
            selection = selection?.limited(toLength: fresh.count)
            lastMatch = nil
            switch method {
            case .patchedCopy(let changed): savedNote = "Saved: \(FieldText.bytes(changed)) changed"
            case .rewritten: savedNote = "Saved"
            }
            resetMap()
            if mode == .map { startMapIfNeeded() }
            startStructure(fresh, keepingView: true)
        case .failure:
            notice = "\(fileName) was saved, but could not be opened again."
        }
    }

    /// Drops the edits, and shows the file as it is on disk.
    func revert() {
        guard let url = fileURL else { return }
        open(url: url)
    }

    // MARK: Finding

    /// Shows the find bar, and asks the pane to put the cursor in it.
    func showFind() {
        guard hasFile else { return }
        showsFind = true
    }

    func closeFind() {
        cancelFind()
        showsFind = false
    }

    func toggleFind() {
        if showsFind { closeFind() } else { showFind() }
    }

    func findNext() { find(.forward) }

    func findPrevious() { find(.backward) }

    private func cancelFind() {
        findCancellation?.cancel()
        findCancellation = nil
        findProgress = nil
    }

    /// Looks for what is in the find bar, from the cursor, in `direction`, and round again if it is not found that way.
    /// The file is read in the background a megabyte at a time, so a search of a big file can be stopped by searching again.
    private func find(_ direction: SearchDirection) {
        guard let buffer else { return }
        let made: Result<SearchPattern, SearchPattern.Failure>
        switch findKind {
        case .hex: made = SearchPattern.hex(findText)
        case .text: made = SearchPattern.text(findText, encoding: findEncoding, ignoresCase: findIgnoresCase)
        }
        let pattern: SearchPattern
        switch made {
        case .success(let value):
            pattern = value
        case .failure(let failure):
            findStatus = SearchPattern.message(failure)
            return
        }
        cancelFind()
        let token = ParseCancellation()
        findCancellation = token

        // From the cursor: onto it going forward, unless it is the match found last, which is gone past.
        let head = selection?.lowerBound ?? 0
        let onLastMatch = lastMatch != nil && selection?.range == lastMatch
        let start: Int64
        switch direction {
        case .forward: start = onLastMatch ? head + 1 : head
        case .backward: start = head - 1
        }
        findStatus = "Searching…"
        findProgress = 0
        let source = EditedBytesSource(buffer)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lastReport = DispatchTime.now().uptimeNanoseconds
            let outcome = ByteSearcher.find(
                pattern, in: source, startingAt: start, direction: direction, wraps: true,
                isCancelled: { token.isCancelled },
                progress: { fraction in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now - lastReport > 80_000_000 else { return }
                    lastReport = now
                    DispatchQueue.main.async {
                        guard let self, !token.isCancelled, self.findProgress != nil else { return }
                        self.findProgress = fraction
                    }
                }
            )
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.findCancellation = nil
                self.findProgress = nil
                switch outcome {
                case .found(let range):
                    self.showMatch(range, searchedFrom: start, direction: direction)
                case .notFound:
                    self.lastMatch = nil
                    self.findStatus = "No match."
                case .cancelled:
                    self.findStatus = nil
                }
            }
        }
    }

    /// Selects the bytes a search found, brings them to the middle of the dump, and says where they are.
    private func showMatch(_ range: Range<Int64>, searchedFrom start: Int64, direction: SearchDirection) {
        guard range.upperBound <= length else { return }
        lastMatch = range
        selection = ByteSelection(anchor: range.lowerBound, head: range.upperBound - 1)
        reveal = BytesRevealRequest(offset: range.lowerBound, centered: true)
        if mode == .map { mode = .hex }
        if mode == .structure { followSelection(scroll: true) }
        var text = "Found at 0x\(String(range.lowerBound, radix: 16, uppercase: true)) (\(range.lowerBound))"
        switch direction {
        case .forward where range.lowerBound < start: text += " · started again from the top"
        case .backward where range.lowerBound > start: text += " · started again from the end"
        default: break
        }
        findStatus = text
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

    private static func storedColoring() -> ByteMapColoring {
        ByteMapColoring(rawValue: UserDefaults.standard.string(forKey: "bytes.mapColoring") ?? "") ?? .byteClass
    }

    private static func storedFindKind() -> FindKind {
        FindKind(rawValue: UserDefaults.standard.string(forKey: "bytes.findKind") ?? "") ?? .hex
    }

    private static func storedFindEncoding() -> SearchPattern.TextEncoding {
        SearchPattern.TextEncoding(rawValue: UserDefaults.standard.string(forKey: "bytes.findEncoding") ?? "") ?? .utf8
    }

    private static func storedEndianness() -> Endianness {
        Endianness(rawValue: UserDefaults.standard.string(forKey: "bytes.endianness") ?? "") ?? .little
    }
}
