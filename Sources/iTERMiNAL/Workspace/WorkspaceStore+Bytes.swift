import AppKit

/// Handing something to the two byte panels from a context menu: a file to the
/// Bytes viewer, or a few bytes to Byte Tools. One place, so every menu that
/// offers "Open in Bytes" or "Send to Byte Tools" does the same thing.
extension WorkspaceStore {
    /// Shows the file at `path` in the Bytes panel and brings the panel forward.
    /// A folder, a pipe or an unreadable file is not hidden here: the panel says
    /// what it would not open and why, in place of the bytes.
    func openInBytes(path: String) {
        panelBytes.open(url: URL(fileURLWithPath: path))
        openPanel(.bytes)
    }

    /// Opens Byte Tools on `tool`, starting from `bytes`. False, and nothing
    /// changes, when the tool cannot take them (`ByteTool.seed(from:)`).
    @discardableResult
    func sendToByteTools(_ bytes: [UInt8], tool: ByteTool = .universal) -> Bool {
        guard panelByteTools.send(bytes, to: tool) else { return false }
        openPanel(.byteTools)
        return true
    }

    /// Whether text of this length can be handed to Byte Tools. A menu uses it
    /// to leave the entry out, rather than offer one that would do nothing.
    static func fitsByteTools(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= ByteTool.carryLimit
    }

    /// Sends a small file on this Mac to Byte Tools. Returns what to tell the
    /// person when it cannot be done, and nil when the panel is open on it.
    @discardableResult
    func sendFileToByteTools(path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let data = FileManager.default.contents(atPath: path) else {
            return "\(name) could not be read."
        }
        guard WorkspaceStore.fitsByteTools(byteCount: data.count) else {
            return data.isEmpty
                ? "\(name) is empty: there are no bytes to send."
                : "\(name) is too large for Byte Tools (up to \(ByteTool.carryLimit) bytes). Open it in Bytes instead."
        }
        return sendToByteTools(Array(data)) ? nil : "Byte Tools could not take \(name)."
    }
}
