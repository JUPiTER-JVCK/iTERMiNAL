import SwiftUI
import WebKit
import AppKit

/// What the browser tells sites it is. `default` leaves WebKit's own string in
/// place; the rest are the strings those browsers send, for testing how a site
/// answers a phone, another engine, or a crawler.
enum BrowserUserAgent: String, CaseIterable, Identifiable {
    case defaultAgent
    case safariMac
    case chromeMac
    case firefoxMac
    case safariIPhone
    case safariIPad
    case chromeAndroid
    case googlebot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultAgent: return "Default"
        case .safariMac: return "Safari — macOS"
        case .chromeMac: return "Chrome — macOS"
        case .firefoxMac: return "Firefox — macOS"
        case .safariIPhone: return "Safari — iPhone"
        case .safariIPad: return "Safari — iPad"
        case .chromeAndroid: return "Chrome — Android"
        case .googlebot: return "Googlebot"
        }
    }

    /// nil means "use WebKit's own".
    var string: String? {
        switch self {
        case .defaultAgent:
            return nil
        case .safariMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        case .chromeMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        case .firefoxMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:127.0) Gecko/20100101 Firefox/127.0"
        case .safariIPhone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .safariIPad:
            return "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        case .chromeAndroid:
            return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        case .googlebot:
            return "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        }
    }
}

extension BrowserModel {
    /// Opens WebKit's Web Inspector for this page.
    ///
    /// The page's right-click "Inspect Element" is the supported route and is
    /// always there; this is the menu's shortcut to the same window. WebKit
    /// has no public call for it, so it goes through the web view's private
    /// inspector object — checked first, so a WebKit that no longer has it
    /// does nothing rather than crash. Returns whether it was shown.
    @discardableResult
    func showWebInspector() -> Bool {
        let accessor = Selector(("_inspector"))
        guard webView.responds(to: accessor),
              let inspector = webView.value(forKey: "_inspector") as? NSObject else { return false }
        let show = Selector(("show"))
        guard inspector.responds(to: show) else { return false }
        _ = inspector.perform(show)
        return true
    }

    /// Reload that ignores the cache.
    func hardReload() { webView.reloadFromOrigin() }

    func copyScreenshotToPasteboard() {
        screenshot { result in
            guard case .success(let data) = result, let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }
}

/// The page as it is now — the live DOM, so what scripts have built is in it —
/// in a window you can read and copy from.
struct BrowserSourceSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = "Loading…"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page Source").font(.headline)
                Text(model.urlText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(source)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            model.html { result in
                switch result {
                case .success(let html): source = html
                case .failure(let error): source = "Could not read the page: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Runs JavaScript in the page and shows what comes back.
struct BrowserConsoleSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var entries: [Entry] = []

    private struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let output: String
        let failed: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("JavaScript Console").font(.headline)
                Text(model.urlText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Clear") { entries.removeAll() }.disabled(entries.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("› " + entry.command).foregroundStyle(.secondary)
                            Text(entry.output.isEmpty ? "undefined" : entry.output)
                                .foregroundStyle(entry.failed ? Color.red : Color.primary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            Divider()
            TextField("Evaluate JavaScript", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .onSubmit(run)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func run() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        input = ""
        model.evaluate(command) { result in
            switch result {
            case .success(let value):
                entries.append(Entry(command: command, output: value, failed: false))
            case .failure(let error):
                entries.append(Entry(command: command, output: error.localizedDescription, failed: true))
            }
        }
    }
}
