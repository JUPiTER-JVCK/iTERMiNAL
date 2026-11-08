import SwiftUI
import AppKit

/// One note.
struct NoteDoc: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var updatedAt = Date()

    /// The first line that says anything, for a tab or a sidebar row.
    var title: String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
        }
        return "Untitled"
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Scratchpads in the trailing panel: the command you are about to run, the
/// host you were given, the three steps you keep re-deriving.
///
/// Notes are tabs, like the browser's. Closing a tab puts the note away — it
/// stays *saved* and is listed in the sidebar to open again — except an empty
/// one, which is simply dropped. They are kept together in one file on this
/// Mac, `Notes/notes.json`, and belong to no space: they used to be keyed by
/// space, which meant a space that was recreated (or restored under a new id)
/// lost its note. The file is outside the workspace snapshot for the reason
/// `TranscriptStore` is: the snapshot is documented as carrying no secrets and
/// is meant to be shareable, and free text a user typed is the least
/// predictable content in the app. Notes survive relaunch; they do not travel
/// in an export.
final class NotesModel: ObservableObject {
    enum SaveStatus: Equatable {
        case saved
        case unsaved
        case failed(String)
    }

    @Published private(set) var notes: [NoteDoc] = []
    /// The notes showing as tabs, in order.
    @Published private(set) var openIDs: [UUID] = []
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { scheduleSave() } }
    }
    @Published private(set) var saveStatus: SaveStatus = .saved

    private var pendingSave: DispatchWorkItem?

    private struct Stored: Codable {
        var notes: [NoteDoc]
        var openIDs: [UUID]
        var selectedID: UUID?
    }

    private static let baseDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iTERMiNAL", isDirectory: true)
    }()

    private static var notesDirectory: URL {
        baseDirectory.appendingPathComponent("Notes", isDirectory: true)
    }

    private static var storeURL: URL {
        notesDirectory.appendingPathComponent("notes.json")
    }

    /// The single file notes lived in before they were per space.
    private static var legacyFileURL: URL {
        baseDirectory.appendingPathComponent("Notes.txt")
    }

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            notes = stored.notes
            openIDs = stored.openIDs.filter { id in stored.notes.contains { $0.id == id } }
            selectedID = stored.selectedID
        } else {
            migrateOlderNotes()
        }
        ensureOneOpen()
    }

    /// Picks up what earlier versions wrote — a text file per space in
    /// `Notes/`, and before that one `Notes.txt` — so nothing written before
    /// this change is lost. The old files are left where they are.
    private func migrateOlderNotes() {
        var urls: [URL] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: Self.notesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            urls += files.filter { $0.pathExtension == "txt" }
        }
        urls.append(Self.legacyFileURL)
        var found: [NoteDoc] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let note = NoteDoc(text: text, updatedAt: modified)
            if !note.isEmpty { found.append(note) }
        }
        notes = found.sorted { $0.updatedAt > $1.updatedAt }
        if let first = notes.first {
            openIDs = [first.id]
            selectedID = first.id
        }
        if !notes.isEmpty { saveNow() }
    }

    // MARK: Reading

    func note(_ id: UUID) -> NoteDoc? {
        notes.first { $0.id == id }
    }

    func text(of id: UUID) -> String {
        note(id)?.text ?? ""
    }

    var openNotes: [NoteDoc] {
        openIDs.compactMap { note($0) }
    }

    var selectedNote: NoteDoc? {
        selectedID.flatMap { note($0) }
    }

    func isOpen(_ id: UUID) -> Bool {
        openIDs.contains(id)
    }

    // MARK: Editing

    func setText(_ text: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    /// Replaces the text of the note being looked at.
    func setSelectedText(_ text: String) {
        if let id = selectedID { setText(text, for: id) }
    }

    /// A new, empty note, in a tab of its own.
    @discardableResult
    func newNote() -> UUID {
        let note = NoteDoc()
        notes.append(note)
        openIDs.append(note.id)
        selectedID = note.id
        scheduleSave()
        return note.id
    }

    /// Shows a saved note as a tab, and goes to it.
    func open(_ id: UUID) {
        guard note(id) != nil else { return }
        if !openIDs.contains(id) { openIDs.append(id) }
        selectedID = id
        scheduleSave()
    }

    /// Closes the tab. The note stays saved — only an empty one is dropped.
    func close(_ id: UUID) {
        guard let position = openIDs.firstIndex(of: id) else { return }
        openIDs.remove(at: position)
        if let note = note(id), note.isEmpty {
            notes.removeAll { $0.id == id }
        }
        if selectedID == id {
            selectedID = openIDs.indices.contains(position) ? openIDs[position] : openIDs.last
        }
        ensureOneOpen()
        scheduleSave()
    }

    /// Removes a note for good, open or not.
    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        openIDs.removeAll { $0 == id }
        if selectedID == id { selectedID = openIDs.last }
        ensureOneOpen()
        scheduleSave()
    }

    /// The panel always has a page to write on.
    private func ensureOneOpen() {
        if openIDs.isEmpty {
            // An empty note left over from before is reused rather than piled up.
            if let blank = notes.first(where: { $0.isEmpty }) {
                openIDs = [blank.id]
                selectedID = blank.id
            } else {
                let note = NoteDoc()
                notes.append(note)
                openIDs = [note.id]
                selectedID = note.id
            }
        } else if selectedID == nil || !openIDs.contains(selectedID!) {
            selectedID = openIDs.first
        }
    }

    // MARK: Saving

    /// Debounced rather than written per keystroke — this is on the main
    /// thread and a note can be long.
    private func scheduleSave() {
        saveStatus = .unsaved
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes immediately. Called on quit, where a debounced save would never
    /// fire and the last thing typed would be the thing lost, and by the Save
    /// button. A failure is kept in `saveStatus` for the panel to show.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let stored = Stored(notes: notes, openIDs: openIDs, selectedID: selectedID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(stored)
            try FileManager.default.createDirectory(
                at: Self.notesDirectory, withIntermediateDirectories: true
            )
            try data.write(to: Self.storeURL, options: [.atomic])
            // Owner-only, matching transcripts: nothing else on the machine
            // has a reason to read what the user jotted down.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.storeURL.path
            )
            saveStatus = .saved
        } catch {
            NSLog("Failed to save notes: \(error.localizedDescription)")
            saveStatus = .failed(error.localizedDescription)
        }
    }
}

struct NotesPaneView: View {
    @ObservedObject var model: NotesModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 0) {
            tabStrip(theme: theme)
            FadedDivider()
            editor(theme: theme)
            FadedDivider()
            footer(theme: theme)
        }
        .background(theme.background)
    }

    private func tabStrip(theme: Theme) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.openNotes) { note in
                        NoteTabChip(
                            title: note.title,
                            isSelected: model.selectedID == note.id,
                            onSelect: { model.selectedID = note.id },
                            onClose: { model.close(note.id) }
                        )
                    }
                }
            }

            Button {
                model.newNote()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func editor(theme: Theme) -> some View {
        if let id = model.selectedID {
            TextEditor(text: Binding(
                get: { model.text(of: id) },
                set: { model.setText($0, for: id) }
            ))
            .id(id)
            // The editor draws its own background, which ignores the app's
            // theme and leaves a white slab in dark mode.
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .font(.system(size: 13))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .overlay(alignment: .topLeading) {
                if model.text(of: id).isEmpty {
                    Text("Write a note. Saved as you type.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 15)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
        } else {
            Spacer()
        }
    }

    private func footer(theme: Theme) -> some View {
        let text = model.selectedID.map { model.text(of: $0) } ?? ""
        return HStack(spacing: 8) {
            Text("\(text.count) character\(text.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)

            statusLabel(theme: theme)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .help("Copy this note")

            Button {
                model.saveNow()
            } label: {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save now")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    @ViewBuilder
    private func statusLabel(theme: Theme) -> some View {
        switch model.saveStatus {
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        case .unsaved:
            Text("Saving…")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        case .failed(let reason):
            Label("Couldn't save", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
                .help(reason)
        }
    }
}

/// One note's tab: its first line, and a close button that puts it away.
private struct NoteTabChip: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab — the note stays saved")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? theme.surface : theme.surface.opacity(hovering ? 0.5 : 0))
        )
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
