import SwiftUI
import AppKit

/// The colours and fonts every Byte Tools view draws with, made once by the
/// pane and handed down, so a tool's view does not repeat the environment
/// plumbing.
struct BTStyle {
    let theme: Theme
    let accent: Color
    /// The fill of a text field, opaque like the composer's.
    let input: Color

    var mono: Font { .system(size: 12, design: .monospaced) }
    var monoLarge: Font { .system(size: 14, weight: .medium, design: .monospaced) }
    var caption: Font { .system(size: 10, weight: .semibold) }

    var primary: Color { theme.textPrimary }
    var secondary: Color { theme.textSecondary }
}

// MARK: - Text

struct BTLabel: View {
    let ui: BTStyle
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(ui.caption)
            .tracking(0.5)
            .foregroundStyle(ui.secondary)
    }
}

/// A line of explanation or a problem, under a field.
struct BTNote: View {
    let ui: BTStyle
    let text: String
    var isProblem = false

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isProblem ? Color.red : ui.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Containers

struct BTCard<Content: View>: View {
    let ui: BTStyle
    let title: String?
    let content: Content

    init(ui: BTStyle, title: String? = nil, @ViewBuilder content: () -> Content) {
        self.ui = ui
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                BTLabel(ui: ui, text: title)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ui.theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ui.theme.surfaceBorder)
        )
    }
}

// MARK: - Inputs

/// A text field, one line or several, drawn like the composer's input.
struct BTInput: View {
    let ui: BTStyle
    let title: String?
    @Binding var text: String
    let placeholder: String
    let lines: Int

    init(ui: BTStyle, title: String? = nil, text: Binding<String>, placeholder: String = "", lines: Int = 1) {
        self.ui = ui
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.lines = lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                BTLabel(ui: ui, text: title)
            }
            if lines > 1 {
                multiLine
            } else {
                singleLine
            }
        }
    }

    private var singleLine: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(ui.mono)
            .foregroundStyle(ui.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.input))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ui.theme.surfaceBorder))
    }

    private var multiLine: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(ui.mono)
                .foregroundStyle(ui.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .font(ui.mono)
                    .foregroundStyle(ui.secondary.opacity(0.6))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: CGFloat(lines) * 16 + 18)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.input))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ui.theme.surfaceBorder))
    }
}

/// A row of chips of which one is chosen, wrapping when the panel is narrow.
struct BTChoice: View {
    let ui: BTStyle
    let title: String?
    @Binding var selection: String
    let options: [(value: String, title: String)]

    init(ui: BTStyle, title: String? = nil, selection: Binding<String>, options: [(value: String, title: String)]) {
        self.ui = ui
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                BTLabel(ui: ui, text: title)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    chip(value: option.value, title: option.title)
                }
            }
        }
    }

    private func chip(value: String, title: String) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(ui.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? ui.accent.opacity(0.30) : ui.theme.surfaceHover))
                .overlay(Capsule().strokeBorder(isSelected ? ui.accent.opacity(0.8) : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small button for one action beside a field.
struct BTButton: View {
    let ui: BTStyle
    let title: String
    let symbol: String?
    let action: () -> Void

    init(ui: BTStyle, title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.ui = ui
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(ui.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(ui.accent.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Results

/// A label, a value you can select, and a button that copies it.
struct BTValueRow: View {
    let ui: BTStyle
    let label: String
    let value: String
    let tint: Color?
    /// When set, a second button puts this value back into the tool as its input.
    let onUse: (() -> Void)?

    @State private var copied = false

    init(ui: BTStyle, label: String, value: String, tint: Color? = nil, onUse: (() -> Void)? = nil) {
        self.ui = ui
        self.label = label
        self.value = value
        self.tint = tint
        self.onUse = onUse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                BTLabel(ui: ui, text: label)
                Spacer(minLength: 4)
                if let onUse {
                    iconButton(symbol: "arrow.up.circle", help: "Use this as the input", action: onUse)
                }
                iconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy", action: copy)
            }
            Text(value.isEmpty ? " " : value)
                .font(ui.monoLarge)
                .foregroundStyle(tint ?? ui.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ui.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func copy() {
        BTClipboard.copy(value)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }
}

/// A coloured tag with a few capital letters: SCHEME, HOST, PORT.
struct BTBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color))
    }
}

// MARK: - Bits

/// A run of bits drawn as cells, most significant first, in rows, optionally
/// tappable. Bit index 0 is the lowest.
struct BTBitRows: View {
    let ui: BTStyle
    let bits: [Bool]
    let perRow: Int
    let cell: CGFloat
    /// The colour of a set bit, by its index (0 lowest).
    let tint: (Int) -> Color
    /// A small number under each cell, by bit index, when set.
    let caption: ((Int) -> String?)?
    let onToggle: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rowStarts, id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(start..<min(start + perRow, bits.count), id: \.self) { position in
                        bitCell(position: position)
                    }
                }
            }
        }
    }

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: bits.count, by: max(1, perRow)))
    }

    private func bitCell(position: Int) -> some View {
        let index = bits.count - 1 - position
        let isSet = bits[position]
        let color = tint(index)
        return VStack(spacing: 2) {
            Button {
                onToggle?(index)
            } label: {
                Text(isSet ? "1" : "0")
                    .font(.system(size: cell * 0.46, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSet ? Color.white : ui.secondary)
                    .frame(width: cell, height: cell * 1.1)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSet ? color : ui.theme.surfaceHover)
                    )
            }
            .buttonStyle(.plain)
            .allowsHitTesting(onToggle != nil)
            .accessibilityLabel("Bit \(index), \(isSet ? "1" : "0")")
            if let caption, let text = caption(index) {
                Text(text)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(ui.secondary)
                    .frame(width: cell)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

// MARK: - Bytes

/// Bytes as small hex chips, each with its position.
struct BTByteChips: View {
    let ui: BTStyle
    let bytes: [UInt8]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(bytes.prefix(256).enumerated()), id: \.offset) { _, byte in
                Text(BTByteChips.hex(byte))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.16)))
            }
        }
    }

    static func hex(_ byte: UInt8) -> String {
        let text = String(byte, radix: 16, uppercase: true)
        return text.count < 2 ? "0" + text : text
    }
}

// MARK: - Send to another tool

/// The "Send to…" menu: hands bytes to any other tool, which opens with them
/// as its input. This is how each tool converts to every other.
struct BTSendMenu: View {
    let ui: BTStyle
    let from: ByteTool
    let bytes: [UInt8]
    @ObservedObject var model: ByteToolsModel

    var body: some View {
        Menu {
            ForEach(ByteToolGroup.allCases) { group in
                Section(group.title) {
                    ForEach(ByteTool.tools(in: group).filter { $0 != from }) { tool in
                        Button(tool.title) {
                            model.send(bytes, to: tool)
                        }
                        .disabled(!tool.accepts(bytes))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 11, weight: .medium))
                Text("Send to…")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(ui.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(ui.theme.surfaceHover))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open another tool starting from these \(bytes.count) bytes")
    }
}

// MARK: - Tool tiles

/// The coloured square with a tool's mark, as on the home screen.
struct BTGlyphTile: View {
    let tool: ByteTool
    let size: CGFloat

    var body: some View {
        let tint = Color(hex: tool.tint)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.20))
            glyph(tint: tint)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func glyph(tint: Color) -> some View {
        switch tool.glyph {
        case .text(let text):
            Text(text)
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

/// One tool on the home screen.
struct BTToolCard: View {
    let ui: BTStyle
    let tool: ByteTool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                BTGlyphTile(tool: tool, size: 42)
                Text(tool.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ui.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(tool.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(ui.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? ui.theme.surfaceHover : ui.theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Color(hex: tool.tint).opacity(0.55) : ui.theme.surfaceBorder)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("\(tool.title). \(tool.subtitle)")
    }
}
