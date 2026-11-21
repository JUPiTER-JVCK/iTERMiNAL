import SwiftUI
import AppKit

/// The Byte Tools panel: a screen of tools to pick from, and, once one is
/// picked, that tool. Every tool is live — type, and every result updates — and
/// every tool can hand its bytes to every other (the "Send to…" menu), so any
/// format can be taken to any other by way of the tools in between.
struct ByteToolsPaneView: View {
    @ObservedObject var model: ByteToolsModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let ui = BTStyle(
            theme: theme,
            accent: settings.accentColor,
            input: Color(hex: Theme.inputFieldHex(for: colorScheme, themeID: appThemeID))
        )
        VStack(spacing: 0) {
            if let tool = model.selected {
                toolHeader(tool, ui: ui)
                FadedDivider()
                ScrollView {
                    ByteToolBody(tool: tool, model: model, ui: ui)
                        .id(tool.rawValue)
                        .padding(14)
                }
            } else {
                homeHeader(ui: ui)
                FadedDivider()
                ScrollView {
                    homeContent(ui: ui)
                        .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    // MARK: Home

    private func homeHeader(ui: BTStyle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(ui.secondary)
            TextField("Find a tool: sha256, endian, 0x, jwt…", text: $model.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ui.primary)
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ui.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func homeContent(ui: BTStyle) -> some View {
        let columns = [GridItem(.adaptive(minimum: 138, maximum: 220), spacing: 10)]
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 18) {
            if query.isEmpty {
                ForEach(ByteToolGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        BTLabel(ui: ui, text: group.title)
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(ByteTool.tools(in: group)) { tool in
                                BTToolCard(ui: ui, tool: tool) { model.open(tool) }
                            }
                        }
                    }
                }
            } else {
                let found = ByteTool.matching(query)
                if found.isEmpty {
                    BTNote(ui: ui, text: "No tool matches “\(query)”. Try a format (base64, hex), an algorithm (sha256, crc32) or a word (endian, epoch).")
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(found) { tool in
                            BTToolCard(ui: ui, tool: tool) { model.open(tool) }
                        }
                    }
                }
            }
        }
    }

    // MARK: A tool

    private func toolHeader(_ tool: ByteTool, ui: BTStyle) -> some View {
        HStack(spacing: 10) {
            Button {
                model.goHome()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Tools")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(ui.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to all tools")
            .accessibilityLabel("Back to all tools")

            BTGlyphTile(tool: tool, size: 24)
            Text(tool.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ui.primary)
                .lineLimit(1)
            Spacer(minLength: 4)

            Button {
                model.reset(tool)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ui.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put this tool's example back")
            .accessibilityLabel("Reset \(tool.title)")

            switchMenu(current: tool, ui: ui)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func switchMenu(current: ByteTool, ui: BTStyle) -> some View {
        Menu {
            ForEach(ByteToolGroup.allCases) { group in
                Section(group.title) {
                    ForEach(ByteTool.tools(in: group)) { tool in
                        Button(tool.title) { model.open(tool) }
                            .disabled(tool == current)
                    }
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12))
                .foregroundStyle(ui.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch tool")
    }
}

/// Picks the view for a tool.
struct ByteToolBody: View {
    let tool: ByteTool
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .universal: UniversalToolView(model: model, ui: ui)
        case .binary: NumberBaseToolView(model: model, ui: ui, tool: .binary, base: 2)
        case .decimal: NumberBaseToolView(model: model, ui: ui, tool: .decimal, base: 10)
        case .hex: NumberBaseToolView(model: model, ui: ui, tool: .hex, base: 16)
        case .octal: NumberBaseToolView(model: model, ui: ui, tool: .octal, base: 8)
        case .baseN: BaseConverterToolView(model: model, ui: ui)
        case .twosComplement: BitEditorToolView(model: model, ui: ui, tool: .twosComplement)
        case .bitsAndBytes: BitEditorToolView(model: model, ui: ui, tool: .bitsAndBytes)
        case .bitwise: BitwiseToolView(model: model, ui: ui)
        case .float: FloatToolView(model: model, ui: ui)
        case .varint: VarintToolView(model: model, ui: ui)
        case .textConverter: TextConverterToolView(model: model, ui: ui)
        case .utf8: UTF8ToolView(model: model, ui: ui)
        case .asciiTable: ASCIITableToolView(model: model, ui: ui)
        case .base64: Base64ToolView(model: model, ui: ui)
        case .baseEncodings: BaseEncodingsToolView(model: model, ui: ui)
        case .urlEncoding: URLEncodingToolView(model: model, ui: ui)
        case .urlAnatomy: URLAnatomyToolView(model: model, ui: ui)
        case .punycode: PunycodeToolView(model: model, ui: ui)
        case .htmlEntities: HTMLEntitiesToolView(model: model, ui: ui)
        case .hexdump: HexdumpToolView(model: model, ui: ui)
        case .asn1: ASN1ToolView(model: model, ui: ui)
        case .hashes: HashesToolView(model: model, ui: ui)
        case .timestamp: TimestampToolView(model: model, ui: ui)
        case .uuid: UUIDToolView(model: model, ui: ui)
        case .jwt: JWTToolView(model: model, ui: ui)
        case .xorCiphers: XORCiphersToolView(model: model, ui: ui)
        case .morse: MorseToolView(model: model, ui: ui)
        case .byteOrder: ByteOrderToolView(model: model, ui: ui)
        case .sizes: SizesToolView(model: model, ui: ui)
        case .ipAddress: IPAddressToolView(model: model, ui: ui)
        }
    }
}
