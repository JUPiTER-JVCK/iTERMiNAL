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
    @FocusState private var findFocused: Bool

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 0) {
            if let buffer = model.buffer {
                header(theme: theme)
                modeBar(theme: theme)
                if model.isWritable { editBar(theme: theme) }
                if model.showsFind { findBar(theme: theme) }
                FadedDivider()
                if let refusal = model.refusal {
                    noticeStrip(refusal.message, isError: refusal.isProblem, theme: theme, dismiss: model.dismissRefusal)
                }
                if let notice = model.notice {
                    noticeStrip(notice, isError: true, theme: theme, dismiss: model.dismissNotice)
                }
                outlook(buffer: buffer, theme: theme)
                FadedDivider()
                statusStrip(theme: theme)
                // In the Structure and Map outlooks the room is better kept for the tree, or the picture,
                // and the dump; the tree's own detail line says what a field is, and the map's what a
                // part of the file is.
                if model.showsInspector, model.mode == .hex || model.mode == .bits {
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
        .onChange(of: model.showsFind) { _, shown in
            if shown { findFocused = true }
        }
    }

    // MARK: The dump, and what is above it

    /// The dump alone, or under the tree of fields in the Structure outlook, or under the map.
    ///
    /// The dump is the last view of the stack in every outlook, so it stays the same view,
    /// and keeps its place in the file, when the outlook changes: a view that moved to another
    /// place in the stack would be made again, and start at the top.
    private func outlook(buffer: ByteEditBuffer, theme: Theme) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.mode == .structure {
                    StructureTreeView(model: model, theme: theme, accent: settings.accentColor)
                        .frame(height: max(120, geometry.size.height * 0.5))
                    FadedDivider()
                }
                if model.mode == .map {
                    ByteMapView(model: model, theme: theme, accent: settings.accentColor)
                        .frame(height: mapHeight(in: geometry.size.height))
                        .clipped()
                    FadedDivider()
                }
                dump(buffer: buffer, theme: theme)
            }
        }
    }

    /// The map wants most of the room, since it is a picture; the dump keeps at least a few rows.
    private func mapHeight(in available: CGFloat) -> CGFloat {
        min(max(300, available * 0.68), max(available - 110, 140))
    }

    private func dump(buffer: ByteEditBuffer, theme: Theme) -> some View {
        HexGridView(
            buffer: buffer,
            radix: model.radix,
            bytesPerRow: model.bytesPerRow,
            showsText: model.showsText,
            selection: model.selection,
            reveal: model.reveal,
            style: gridStyle(theme: theme),
            onSelect: { model.select($0) },
            onCopy: { model.copySelection(as: .spacedHex) },
            onFind: { command in
                switch command {
                case .show:
                    model.showFind()
                    findFocused = true
                case .next: model.findNext()
                case .previous: model.findPrevious()
                }
            },
            isEditable: model.isWritable,
            takesHexDigits: model.radix == .hex,
            takesBits: model.radix == .binary,
            bitColumn: model.bitColumn,
            onEdit: { edit in
                switch edit {
                case .hexDigit(let digit): model.typeHexDigit(digit)
                case .bit(let value): model.typeBit(value)
                case .placeBit(let index): model.placeBit(index)
                case .text(let text): model.typeText(text)
                case .deleteBackward: model.deleteBackward()
                case .deleteForward: model.deleteForward()
                case .undo: model.undo()
                case .redo: model.redo()
                case .save: model.save()
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bytes of \(model.fileName)")
        .accessibilityValue(selectionSummary)
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
            if model.isDirty {
                Circle()
                    .fill(settings.accentColor)
                    .frame(width: 7, height: 7)
                    .help("Changed, and not saved")
                    .accessibilityLabel("Changed, and not saved")
            }
            if !model.isWritable {
                Text("Read-only")
                    .font(.system(size: 10))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.surface))
                    .help(model.readOnlyReason ?? "This file can be looked at but not changed")
            }
            Text(sizeText)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: model.toggleFind) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Find bytes or text in the file (⌘F while the dump has the keys; ⌘G for the next, ⇧⌘G for the one before)")
            .accessibilityLabel("Find in the file")
            Button(action: chooseFile) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Open another file")
            .accessibilityLabel("Open another file")
            Button(action: { confirmThen { model.close() } }) {
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
                    (BytesMode.bits, "Bits"),
                    (BytesMode.structure, "Structure"),
                    (BytesMode.map, "Map")
                ]
            )
            .help("Hex: every byte as a number, with the text beside it · Bits: every byte as its eight bits · Structure: the fields the file's format says it is made of, beside their bytes · Map: how random each part is, and the whole file as a picture")
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

    private func editBar(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Picker("Typing", selection: $model.editMode) {
                Text("Overwrite").tag(ByteTyping.Mode.overwrite)
                Text("Insert").tag(ByteTyping.Mode.insert)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Overwrite changes the bytes you type over, so nothing moves. Insert puts new bytes in before the cursor, and lets Delete take bytes out; everything after them moves.")
            Button(action: model.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .help("Undo (⌘Z)")
            .accessibilityLabel("Undo")
            Button(action: model.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .help("Redo (⇧⌘Z)")
            .accessibilityLabel("Redo")
            Menu {
                Button("Fill the selection with 00") { model.fillSelection(with: 0x00) }
                    .disabled(model.selection == nil)
                Button("Fill the selection with FF") { model.fillSelection(with: 0xFF) }
                    .disabled(model.selection == nil)
                Button("Add bytes at the end") { model.beginAppending() }
                Divider()
                Toggle("Keep the old file as .bak when saving", isOn: $model.keepsBackup)
                Divider()
                Button("Revert to the saved file…") { confirmRevert() }
                    .disabled(!model.isDirty)
            } label: {
                Text("Edit")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Click the dump and type: hex digits in the cells when they are shown as hex, 0 and 1 when they are shown as bits (click a digit to choose the bit), characters in the text column. The heavier outline shows what takes the typing.")
            Spacer(minLength: 0)
            if let note = model.savedNote {
                Text(note)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Button(action: { model.save() }) {
                Text(model.isSaving ? "Saving…" : "Save")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.isDirty || model.isSaving)
            .help("Write the changes into the file (⌘S): into a new file that replaces it, so a failure leaves the original as it was")
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func findBar(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Picker("Look for", selection: $model.findKind) {
                    Text("Hex").tag(BytesViewerModel.FindKind.hex)
                    Text("Text").tag(BytesViewerModel.FindKind.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 86)
                .help("Hex: bytes such as DE AD ?? EF, where ?? is any byte · Text: letters, in the encoding chosen")
                TextField(model.findKind == .hex ? "DE AD ?? EF" : "Text to find", text: $model.findText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.surface))
                    .focused($findFocused)
                    .onSubmit { model.findNext() }
                    .onExitCommand { model.closeFind() }
                if model.findKind == .text {
                    Toggle(isOn: $model.findIgnoresCase) {
                        Text("Aa")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .toggleStyle(.button)
                    .help("Ignore the case of A to Z")
                    Menu {
                        Picker("Look for it as", selection: $model.findEncoding) {
                            ForEach(SearchPattern.TextEncoding.allCases, id: \.self) { encoding in
                                Text(encoding.title).tag(encoding)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(model.findEncoding.title)
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("The bytes the text is looked for as")
                }
                Button(action: model.findPrevious) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(model.findText.isEmpty)
                .help("The match before the cursor")
                .accessibilityLabel("Find the previous match")
                Button(action: model.findNext) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(model.findText.isEmpty)
                .help("The match after the cursor")
                .accessibilityLabel("Find the next match")
                Button(action: model.closeFind) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close the find bar")
                .accessibilityLabel("Close the find bar")
            }
            if model.findStatus != nil || model.findProgress != nil {
                HStack(spacing: 6) {
                    if let progress = model.findProgress {
                        ProgressView(value: progress)
                            .frame(width: 60)
                    }
                    Text(model.findStatus ?? "")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(theme.textSecondary)
            }
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var displayMenu: some View {
        Menu {
            if model.mode != .bits {
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
            confirmThen { model.open(url: url) }
        }
    }

    /// Asks what to do with changes that are not saved before something that would lose them, and does `action` if the
    /// answer is to go on: after saving, or without.
    private func confirmThen(_ action: @escaping () -> Void) {
        guard model.isDirty else {
            action()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save the changes to \(model.fileName)?"
        alert.informativeText = "The bytes you changed are not in the file yet. If you go on without saving them, they are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save { saved in
                if saved { action() }
            }
        case .alertSecondButtonReturn:
            action()
        default:
            break
        }
    }

    /// Asks before dropping every change since the last save.
    private func confirmRevert() {
        let alert = NSAlert()
        alert.messageText = "Go back to the saved \(model.fileName)?"
        alert.informativeText = "Every change since it was last saved is lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.revert() }
    }

    /// The first thing dropped. loadObject calls back on an arbitrary queue, so
    /// the model is touched from the main one.
    private func openDropped(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                confirmThen { model.open(url: url) }
            }
        }
    }
}
