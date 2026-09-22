import SwiftUI
import AppKit

/// A scratchpad in the trailing panel: the command you are about to run, the
/// host you were given, the three steps you keep re-deriving.
///
/// Kept on this Mac in one file rather than in the workspace snapshot, for the
/// same reason `TranscriptStore` is: the snapshot is documented as carrying no
/// secrets and is meant to be shareable, and free text a user typed is the
/// least predictable content in the app. Notes survive relaunch; they do not
/// travel in an export.
final class NotesModel: ObservableObject {
    /// Debounced rather than written per keystroke — this is on the main
    /// thread and a note can be long.
    @Published var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleSave()
        }
    }

    private var pendingSave: DispatchWorkItem?

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("iTERMiNAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Notes.txt")
    }()

    init() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes immediately. Called on quit, where a debounced save would never
    /// fire and the last thing typed would be the thing lost.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let url = Self.fileURL
        guard let data = text.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: [.atomic])
            // Owner-only, matching transcripts: nothing else on the machine
            // has a reason to read what the user jotted down.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            NSLog("Failed to save notes: \(error.localizedDescription)")
        }
    }

    var characterCount: Int { text.count }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct NotesPaneView: View {
    @ObservedObject var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            TextEditor(text: $model.text)
                // The editor draws its own background, which ignores the app's
                // theme and leaves a white slab in dark mode.
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .font(.system(size: 13))
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .overlay(alignment: .topLeading) {
                    if model.isEmpty {
                        Text("Notes for this machine. Saved as you type.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 15)
                            .padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }

            FadedDivider()

            HStack(spacing: 8) {
                Text("\(model.characterCount) character\(model.characterCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)

                Spacer(minLength: 0)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isEmpty)
                .help("Copy all notes")

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
        .background(theme.background)
    }
}
