import SwiftUI

/// The Skills page: saved commands and snippets.
///
/// Choosing one puts its text in the composer's input, after anything already
/// typed there. It is not sent; you press Return, with what will run in front
/// of you.
struct SkillsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    @State private var editing: Skill?
    @State private var editingIsNew = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skills")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Saved commands and snippets. Choosing one puts it in the composer's input; you press Return to run it.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button {
                    editingIsNew = true
                    editing = Skill(name: Skill.newName(avoiding: settings.skills.map(\.name)))
                } label: {
                    Label("New Skill", systemImage: "plus")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 22)

            if settings.skills.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "book")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(theme.textSecondary)
                    Text("No skills yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text("Save a command you type often, then find it here or in the command palette.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(settings.skills) { skill in
                            row(skill, theme: theme)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { skill in
            SkillEditor(skill: skill, isNew: editingIsNew) { saved in
                if let index = settings.skills.firstIndex(where: { $0.id == saved.id }) {
                    settings.skills[index] = saved
                } else {
                    settings.skills.append(saved)
                }
            }
        }
    }

    private func row(_ skill: Skill, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(skill.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if !skill.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(skill.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Use") {
                    if let text = skill.inputText { store.insertIntoComposer(text) }
                }
                .disabled(skill.inputText == nil)
                .help("Put this in the composer's input")
                Button("Edit") {
                    editingIsNew = false
                    editing = skill
                }
                Button(role: .destructive) {
                    settings.skills.removeAll { $0.id == skill.id }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this skill")
            }
            Text(Skill.normalized(skill.text))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let problem = skill.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.surfaceBorder, lineWidth: 1)
        )
    }
}

/// A skill's name, note and text, in a sheet.
private struct SkillEditor: View {
    @State private var skill: Skill
    let isNew: Bool
    let save: (Skill) -> Void
    @Environment(\.dismiss) private var dismiss

    init(skill: Skill, isNew: Bool, save: @escaping (Skill) -> Void) {
        _skill = State(initialValue: skill)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Skill" : "Edit Skill")
                .font(.headline)
            TextField("Name", text: $skill.name)
            TextField("Note", text: $skill.note, prompt: Text("What it is for (optional)"))
            Text("Text for the input")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $skill.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            if let problem = skill.problem, !skill.text.isEmpty {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("It is put in the input, not run. Several lines are fine; each is sent when you press Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(skill)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(skill.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
