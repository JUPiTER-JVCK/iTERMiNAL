import SwiftUI

/// The list that opens above the composer's input for history search (⌃R) and
/// file completion (Tab).
///
/// It never takes focus: the keys go to the text field, which hands them to
/// `ComposerSuggestions`. Clicking a row works too.
struct SuggestionList: View {
    @ObservedObject var suggestions: ComposerSuggestions
    let theme: Theme
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shared by the selected row's highlight, so it glides from row to row
    /// rather than disappearing from one and appearing on the next.
    @Namespace private var highlight

    var body: some View {
        Group {
            if let mode = suggestions.mode {
                panel(mode: mode)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : Motion.suggestion, value: suggestions.mode)
    }

    private func panel(mode: ComposerSuggestions.Mode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if suggestions.rows.isEmpty {
                Text(mode == .history ? "No matching commands" : "Nothing to complete")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(suggestions.rows) { row in
                    rowView(row, mode: mode)
                }
            }

            footer(mode: mode)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                // Opaque, so the text on it is read against one known colour.
                .fill(Color(p3: Theme.floatingSurfaceHex(for: colorScheme)))
                .shadow(color: theme.elevatedShadow, radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.surfaceBorder, lineWidth: 1)
        )
        .onHover { suggestions.pointerInside = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .history ? "Command history" : "File completions")
    }

    private func rowView(_ row: ComposerSuggestions.Row, mode: ComposerSuggestions.Mode) -> some View {
        let isSelected = row.id == suggestions.selected
        return HStack(spacing: 8) {
            if mode == .path {
                Image(systemName: row.isDirectory ? "folder" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14)
            }
            emphasizedText(row)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            if isSelected {
                // A faint wash of the accent: the text on it keeps its own
                // colour, so the contrast does not depend on which accent
                // was picked.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .matchedGeometryEffect(id: "selection", in: highlight)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { suggestions.choose(row) }
        .animation(reduceMotion ? nil : Motion.suggestion, value: suggestions.selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.text)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The row's text with what the search matched in bold — weight, not
    /// colour, so it reads whatever the theme or accent.
    private func emphasizedText(_ row: ComposerSuggestions.Row) -> Text {
        guard !row.emphasized.isEmpty else { return Text(row.text) }
        var result = Text("")
        var run = ""
        var runIsEmphasized = false
        func flush() {
            guard !run.isEmpty else { return }
            result = result + (runIsEmphasized ? Text(run).bold() : Text(run))
            run = ""
        }
        for (offset, character) in row.text.enumerated() {
            let emphasized = row.emphasized.contains(offset)
            if emphasized != runIsEmphasized { flush() }
            runIsEmphasized = emphasized
            run.append(character)
        }
        flush()
        return result
    }

    private func footer(mode: ComposerSuggestions.Mode) -> some View {
        let hint = mode == .history
            ? "↑↓ choose   ↩ insert   ⌃R next   esc close"
            : "↑↓ choose   ↩ or ⇥ insert   esc close"
        let more = suggestions.hiddenCount > 0 ? "   +\(suggestions.hiddenCount) more — keep typing" : ""
        return Text(hint + more)
            .font(.system(size: 10))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
