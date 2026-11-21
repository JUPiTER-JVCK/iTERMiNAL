import SwiftUI
import AppKit

/// What the Byte Tools panel remembers while the app runs: which tool is open,
/// and what is typed in every tool.
///
/// Every field of every tool lives in one dictionary, under the keys
/// `ByteTool.key(_:)` makes, so that switching tools and coming back finds
/// what was typed, and so that sending bytes from one tool to another is only
/// "set these fields" (`ByteTool.seed(from:)`). Nothing is saved to disk:
/// people paste tokens and keys into a tool like this one, and a panel that
/// quietly kept them would be keeping secrets.
final class ByteToolsModel: ObservableObject {
    /// The open tool, or nil for the home screen with every tool on it.
    @Published var selected: ByteTool?
    @Published var fields: [String: String] = ByteTool.allDefaults
    /// What is typed in the home screen's search.
    @Published var search = ""

    func value(_ tool: ByteTool, _ field: String) -> String {
        fields[tool.key(field)] ?? tool.defaults[field] ?? ""
    }

    func set(_ tool: ByteTool, _ field: String, to value: String) {
        fields[tool.key(field)] = value
    }

    /// A binding to one field, for a text field or a chip row.
    func binding(_ tool: ByteTool, _ field: String) -> Binding<String> {
        Binding<String>(
            get: { self.value(tool, field) },
            set: { self.fields[tool.key(field)] = $0 }
        )
    }

    func open(_ tool: ByteTool) {
        selected = tool
    }

    func goHome() {
        selected = nil
    }

    /// Opens `tool` starting from `bytes`. False, and nothing changes, when the
    /// tool cannot take them (see `ByteTool.seed(from:)`).
    @discardableResult
    func send(_ bytes: [UInt8], to tool: ByteTool) -> Bool {
        guard let seed = tool.seed(from: bytes) else { return false }
        for (field, value) in seed {
            fields[tool.key(field)] = value
        }
        selected = tool
        return true
    }

    /// Puts a tool's example back.
    func reset(_ tool: ByteTool) {
        for (field, value) in tool.defaults {
            fields[tool.key(field)] = value
        }
    }
}

enum BTClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
