import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Bytes panel: drop any file on it and see every byte, in hex or as bits,
/// with what the selected bytes might be beside them.
///
/// It is a dock panel only, like Notes and the HTTP client's side panel. Nothing
/// is read when it opens, and nothing is read when a file is dropped on it that
/// the rows on screen do not need: a 4 GB video opens as fast as a note.
struct BytesViewerPaneView: View {
    @ObservedObject var model: BytesViewerModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var isDropTargeted = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 0) {
            if let buffer = model.buffer {
                header(theme: theme)
                modeBar(theme: theme)
                FadedDivider()
                if let refusal = model.refusal {
                    noticeStrip(refusal.message, isError: refusal.isProblem, theme: theme, dismiss: model.dismissRefusal)
                }
                if let notice = model.notice {
                    noticeStrip(notice, isError: true, theme: theme, dismiss: model.dismissNotice)
                }
                HexGridView(
                    buffer: buffer,
                    radix: model.radix,
                    bytesPerRow: model.bytesPerRow,
                    showsText: model.showsText,
                    selection: model.selection,
                    reveal: model.reveal,
                    style: gridStyle(theme: theme),
                    onSelect: { model.select($0) },
                    onCopy: { model.copySelection(as: .spacedHex) }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Bytes of \(model.fileName)")
                .accessibilityValue(selectionSummary)
                FadedDivider()
                statusStrip(theme: theme)
                if model.showsInspector {
                    FadedDivider()
                    ByteInspectorView(
                        bytes: model.inspectedBytes(),
                        selectedCount: model.selection?.count ?? 0,
                        endianness: $model.endianness,
                        theme: theme
                    )
                    .frame(height: 150)
                }
            } else {
                emptyState(theme: theme)
            }
        }
        .background(theme.background)
        .overlay(dropOutline)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            openDropped(providers)
            return true
        }
    }

    // MARK: Empty

    private func emptyState(theme: Theme) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "number.square")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isDropTargeted ? settings.accentColor : theme.textSecondary)
            Text("Drop a file to see its bytes")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Text("Any file: a packet capture, an image, a video, a PDF, a program. Every byte is there, in hex or as bits, however big it is.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Open File…", action: chooseFile)
                .buttonStyle(.bordered)
            if let refusal = model.refusal {
                Text(refusal.message)
                    .font(.system(size: 11))
                    .foregroundStyle(refusal.isProblem ? Color.red : theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A line round the pane while a file is held over it.
    private var dropOutline: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(settings.accentColor, lineWidth: 2)
            .padding(2)
            .opacity(isDropTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Bars

    private func header(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
            Text(model.fileName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(sizeText)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: chooseFile) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Open another file")
            .accessibilityLabel("Open another file")
            Button(action: model.close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close this file")
            .accessibilityLabel("Close this file")
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func modeBar(theme: Theme) -> some View {
        HStack(spacing: 10) {
            UnderlinedTabBar(
                selection: $model.mode,
                items: [
                    (BytesMode.hex, "Hex"),
                    (BytesMode.bits, "Bits")
                ]
            )
            .help("Hex: every byte as a number, with the text beside it · Bits: every byte as its eight bits")
            Spacer(minLength: 0)
            TextField("Go to offset", text: $model.goToText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 104)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.surface))
                .onSubmit { model.goTo() }
                .help("A byte to go to: 0x1F40, 8000, +16, end-0x20 or 50%")
            displayMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var displayMenu: some View {
        Menu {
            if model.mode == .hex {
                Picker("Show bytes as", selection: $model.cellRadix) {
                    ForEach([ByteRadix.hex, ByteRadix.decimal, ByteRadix.octal], id: \.self) { radix in
                        Text(radix.title).tag(radix)
                    }
                }
                .pickerStyle(.inline)
            }
            Picker("Bytes per row", selection: $model.bytesPerRow) {
                Text("Fit the width").tag(0)
                ForEach(HexGeometry.bytesPerRowChoices, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.inline)
            Toggle("Show text", isOn: $model.showsText)
            Toggle("Show inspector", isOn: $model.showsInspector)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How the bytes are shown")
    }

    private func statusStrip(theme: Theme) -> some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                ForEach(ByteExportFormat.allCases, id: \.self) { format in
                    Button(format.title) { model.copySelection(as: format) }
                }
            } label: {
                Text("Copy as")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.selection == nil)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func noticeStrip(_ text: String, isError: Bool, theme: Theme, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(size: 11))
        }
        .foregroundStyle(isError ? Color.red : theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface)
    }

    // MARK: What they say

    private var sizeText: String {
        let exact = model.length.formatted(.number)
        guard model.length >= 1000 else { return "\(exact) bytes" }
        return "\(ByteCountFormatter.string(fromByteCount: model.length, countStyle: .file)) · \(exact) bytes"
    }

    private var statusText: String {
        guard let selection = model.selection else { return "" }
        let offset = "Offset 0x\(String(selection.head, radix: 16, uppercase: true)) (\(selection.head))"
        guard selection.count > 1 else { return offset }
        return "\(offset) · \(selection.count) bytes selected"
    }

    /// What a screen reader is told about the grid, which it cannot read itself.
    private var selectionSummary: String {
        guard let selection = model.selection else { return "Nothing selected" }
        return "Offset \(selection.head), \(selection.count) \(selection.count == 1 ? "byte" : "bytes") selected"
    }

    private func gridStyle(theme: Theme) -> HexGridStyle {
        let accent = NSColor(settings.accentColor)
        return HexGridStyle(
            background: NSColor(theme.background),
            text: NSColor(theme.textPrimary),
            dimText: NSColor(theme.textSecondary),
            selection: accent.withAlphaComponent(0.35),
            inactiveSelection: accent.withAlphaComponent(0.18),
            cursor: accent,
            missing: NSColor.systemRed
        )
    }

    // MARK: Opening

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to look at, byte by byte"
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url: url)
        }
    }

    /// The first thing dropped. loadObject calls back on an arbitrary queue, so
    /// the model is touched from the main one.
    private func openDropped(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                model.open(url: url)
            }
        }
    }
}
