import SwiftUI

/// A segmented choice drawn in the app's own chrome: a capsule track with a
/// raised pill that slides to whichever option is chosen.
///
/// For a few short, mutually exclusive options in a settings form, where the
/// system's segmented control is the one piece that is not drawn like the rest
/// of the window. It lays out as a form row — the title at the leading edge,
/// the control at the trailing one — as a `Picker` does.
struct PillSegmentedPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]

    init(title: String, selection: Binding<Value>, values: [Value], label: (Value) -> String) {
        self.title = title
        self._selection = selection
        self.options = values.map { Option(value: $0, label: label($0)) }
    }

    @Namespace private var pill
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let dark = colorScheme == .dark
        LabeledContent(title) {
            HStack(spacing: 2) {
                ForEach(options) { option in
                    segment(option, theme: theme, dark: dark)
                }
            }
            .padding(2)
            .background(Capsule().fill(dark ? theme.surface : theme.surfaceHover))
            .overlay(Capsule().strokeBorder(theme.surfaceBorder).allowsHitTesting(false))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
        }
    }

    private func segment(_ option: Option, theme: Theme, dark: Bool) -> some View {
        let isSelected = option.value == selection
        return Button {
            // Under Reduce Motion the pill changes place without travelling.
            withAnimation(reduceMotion ? nil : Motion.suggestion) {
                selection = option.value
            }
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: 64)
                .frame(height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(dark ? theme.surfaceHover : theme.background)
                            .shadow(color: theme.contactShadow, radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selection", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
