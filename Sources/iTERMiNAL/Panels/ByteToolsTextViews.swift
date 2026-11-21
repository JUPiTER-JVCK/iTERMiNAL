import SwiftUI

// MARK: - Shared helpers

/// The chips that choose a format. `auto` adds "Auto-detect" in front.
func btFormatOptions(auto: Bool) -> [(value: String, title: String)] {
    var options: [(value: String, title: String)] = []
    if auto {
        options.append((value: "auto", title: "Auto-detect"))
    }
    for format in ByteFormat.allCases {
        options.append((value: format.rawValue, title: format.title))
    }
    return options
}

/// What a tool's input field stands for: its text as UTF-8, or hex bytes.
func btInputBytes(_ text: String, kind: String) -> Result<[UInt8], ByteFormatProblem> {
    kind == "hex" ? ByteFormat.hex.decode(text) : .success(Array(text.utf8))
}

private let kindOptions: [(value: String, title: String)] = [("text", "Text (UTF-8)"), ("hex", "Hex bytes")]
private let modeOptions: [(value: String, title: String)] = [("encode", "Encode"), ("decode", "Decode")]

/// How many characters of input the tools that print every format will take.
private let universalLimit = 8_000

// MARK: - Universal converter

/// One input, written in every format at once. Type or paste anything — the
/// tool works out what it is, and shows it in all the others.
struct UniversalToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.universal

    private var style: ByteStyle {
        ByteStyle(
            delimiter: model.value(tool, "hexDelimiter"),
            prefix: model.value(tool, "hexPrefix"),
            uppercase: model.value(tool, "hexUpper") == "1"
        )
    }

    var body: some View {
        let full = model.value(tool, "input")
        let input = String(full.prefix(universalLimit))
        let chosen = model.value(tool, "from")
        let detected = ByteFormat.detect(input)
        let format: ByteFormat = ByteFormat(rawValue: chosen) ?? (detected.first ?? .text)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Input", text: model.binding(tool, "input"),
                        placeholder: "Paste text, hex, Base64, a URL-encoded string, a hexdump…", lines: 4)
                BTChoice(ui: ui, title: "Read the input as", selection: model.binding(tool, "from"), options: btFormatOptions(auto: true))
                if chosen == "auto" {
                    BTNote(ui: ui, text: detectionText(format, detected))
                }
                if full.count > universalLimit {
                    BTNote(ui: ui, text: "Only the first \(universalLimit) characters are converted.")
                }
            }
            switch format.decode(input) {
            case .failure(let problem):
                BTNote(ui: ui, text: "As \(format.title): " + problem.message, isProblem: true)
            case .success(let bytes):
                outputs(bytes, format: format)
            }
        }
    }

    private func detectionText(_ format: ByteFormat, _ detected: [ByteFormat]) -> String {
        let others = detected.filter { $0 != format && $0 != .text }
        if others.isEmpty { return "Detected: \(format.title)." }
        return "Detected: \(format.title). It could also be \(others.map(\.title).joined(separator: ", ")) — pick one above to be sure."
    }

    private func outputs(_ bytes: [UInt8], format: ByteFormat) -> some View {
        let currentStyle = style
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "\(bytes.count) byte\(bytes.count == 1 ? "" : "s"), written every way") {
                ForEach(ByteFormat.allCases) { target in
                    BTValueRow(
                        ui: ui,
                        label: target.title,
                        value: target.encode(bytes, style: currentStyle),
                        tint: target == format ? ui.accent : nil,
                        onUse: { use(target, bytes: bytes, style: currentStyle) }
                    )
                }
                if !ByteFormat.isValidUTF8(bytes) {
                    BTNote(ui: ui, text: "These bytes are not valid UTF-8, so the Text row shows � where they are not.")
                }
            }
            BTCard(ui: ui, title: "Hex, binary, octal and decimal-bytes style") {
                BTChoice(ui: ui, title: "Between bytes", selection: model.binding(tool, "hexDelimiter"),
                         options: [(" ", "Space"), ("", "Nothing"), (",", "Comma"), (":", "Colon"), ("-", "Dash")])
                BTChoice(ui: ui, title: "In front of each", selection: model.binding(tool, "hexPrefix"),
                         options: [("", "Nothing"), ("0x", "0x"), ("\\x", "\\x")])
                BTChoice(ui: ui, title: "Hex letters", selection: model.binding(tool, "hexUpper"),
                         options: [("0", "abcdef"), ("1", "ABCDEF")])
            }
            HStack {
                BTSendMenu(ui: ui, from: .universal, bytes: bytes, model: model)
                Spacer()
            }
        }
    }

    private func use(_ target: ByteFormat, bytes: [UInt8], style: ByteStyle) {
        model.set(tool, "input", to: target.encode(bytes, style: style))
        model.set(tool, "from", to: target.rawValue)
    }
}

// MARK: - Text converter

/// Two pickers: what you have, and what you want.
struct TextConverterToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.textConverter

    private var from: ByteFormat { ByteFormat(rawValue: model.value(tool, "from")) ?? .text }
    private var to: ByteFormat { ByteFormat(rawValue: model.value(tool, "to")) ?? .binary }

    private var style: ByteStyle {
        ByteStyle(
            delimiter: model.value(tool, "hexDelimiter"),
            prefix: model.value(tool, "hexPrefix"),
            uppercase: model.value(tool, "hexUpper") == "1"
        )
    }

    var body: some View {
        let input = String(model.value(tool, "input").prefix(universalLimit))
        let result = from.decode(input)
        let usesStyle = [ByteFormat.hex, .binary, .octal, .decimalBytes].contains(to)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Input", text: model.binding(tool, "input"), placeholder: from.example, lines: 4)
                BTChoice(ui: ui, title: "From", selection: model.binding(tool, "from"), options: btFormatOptions(auto: false))
                HStack {
                    Spacer()
                    BTButton(ui: ui, title: "Swap", symbol: "arrow.up.arrow.down") { swap(result) }
                    Spacer()
                }
                BTChoice(ui: ui, title: "To", selection: model.binding(tool, "to"), options: btFormatOptions(auto: false))
                if usesStyle {
                    BTChoice(ui: ui, title: "Between bytes", selection: model.binding(tool, "hexDelimiter"),
                             options: [(" ", "Space"), ("", "Nothing"), (",", "Comma"), (":", "Colon"), ("-", "Dash")])
                    BTChoice(ui: ui, title: "In front of each", selection: model.binding(tool, "hexPrefix"),
                             options: [("", "Nothing"), ("0x", "0x"), ("\\x", "\\x")])
                    if to == .hex {
                        BTChoice(ui: ui, title: "Hex letters", selection: model.binding(tool, "hexUpper"),
                                 options: [("0", "abcdef"), ("1", "ABCDEF")])
                    }
                }
            }
            switch result {
            case .failure(let problem):
                BTNote(ui: ui, text: "As \(from.title): " + problem.message, isProblem: true)
            case .success(let bytes):
                BTCard(ui: ui, title: "\(from.title) → \(to.title)") {
                    BTValueRow(ui: ui, label: "Result", value: to.encode(bytes, style: style), tint: ui.accent, onUse: { useResult(bytes) })
                    BTNote(ui: ui, text: "\(bytes.count) byte\(bytes.count == 1 ? "" : "s")")
                }
                HStack {
                    BTSendMenu(ui: ui, from: .textConverter, bytes: bytes, model: model)
                    Spacer()
                }
            }
        }
    }

    private func useResult(_ bytes: [UInt8]) {
        model.set(tool, "input", to: to.encode(bytes, style: style))
        model.set(tool, "from", to: to.rawValue)
    }

    private func swap(_ result: Result<[UInt8], ByteFormatProblem>) {
        let oldFrom = from
        let oldTo = to
        if case .success(let bytes) = result {
            model.set(tool, "input", to: oldTo.encode(bytes, style: style))
        }
        model.set(tool, "from", to: oldTo.rawValue)
        model.set(tool, "to", to: oldFrom.rawValue)
    }
}

// MARK: - Text → UTF-8

struct UTF8ToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.utf8

    var body: some View {
        let text = model.value(tool, "input")
        let counts = UTF8Breakdown.counts(text)
        let cards = UTF8Breakdown.cards(text, limit: 240)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "A character isn’t a byte. UTF-8 writes each Unicode code point in 1–4 bytes: ASCII stays one byte, accented letters take two, most symbols three, emoji four.")
                BTInput(ui: ui, title: "Text", text: model.binding(tool, "input"), placeholder: "Type anything — try é, 日本語 or 😀", lines: 3)
            }
            HStack(spacing: 8) {
                stat("\(counts.characters)", "characters")
                stat("\(counts.scalars)", "code points")
                stat("\(counts.utf8Bytes)", "UTF-8 bytes")
                stat("\(counts.utf16Units)", "UTF-16 units")
            }
            if counts.characters != counts.scalars {
                BTNote(ui: ui, text: "Some of what looks like one character is several code points (an emoji with a skin tone, a letter with a combining accent). That is why the counts differ.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 8)], spacing: 8) {
                ForEach(cards) { card in
                    cardView(card)
                }
            }
            if text.unicodeScalars.count > cards.count {
                BTNote(ui: ui, text: "Showing the first \(cards.count) code points.")
            }
            BTCard(ui: ui, title: "Whole text") {
                BTValueRow(ui: ui, label: "UTF-8 bytes", value: ByteFormat.hex.encode(Array(text.utf8), style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
                BTValueRow(ui: ui, label: "UTF-16 code units", value: text.utf16.map { unit -> String in
                    let hex = String(unit, radix: 16, uppercase: true)
                    return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                }.joined(separator: " "))
                BTValueRow(ui: ui, label: "Code points", value: cards.map(\.codePoint).joined(separator: " "))
            }
            HStack {
                BTSendMenu(ui: ui, from: .utf8, bytes: Array(text.utf8), model: model)
                Spacer()
            }
        }
    }

    private func stat(_ number: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(number)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ui.primary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(ui.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ui.theme.surfaceBorder))
    }

    private func color(forBytes count: Int) -> Color {
        switch count {
        case 1: return Color.green
        case 2: return Color.blue
        case 3: return Color.orange
        default: return Color.pink
        }
    }

    private func cardView(_ card: CodePointCard) -> some View {
        let tint = color(forBytes: card.utf8.count)
        return VStack(spacing: 3) {
            Text(card.glyph)
                .font(.system(size: 22))
                .foregroundStyle(ui.primary)
                .frame(height: 28)
            Text(card.codePoint)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ui.secondary)
            Text(card.utf8Hex)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(ui.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(card.utf8.count)B")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.55)))
        .help(card.name ?? card.codePoint)
    }
}

// MARK: - ASCII table

struct ASCIITableToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.asciiTable
    private static let basic = ASCIITable.entries(extended: false)
    private static let extended = ASCIITable.entries(extended: true)

    var body: some View {
        let all = model.value(tool, "extended") == "1" ? ASCIITableToolView.extended : ASCIITableToolView.basic
        let shown = ASCIITable.filter(all, query: model.value(tool, "query"))
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Find", text: model.binding(tool, "query"), placeholder: "A, 65, 0x41, 01000001, lf, escape, newline…")
                BTChoice(ui: ui, selection: model.binding(tool, "extended"), options: [("0", "ASCII 0–127"), ("1", "Plus Latin-1 128–255")])
                BTNote(ui: ui, text: "Click a row to copy the character (or its hex code, for a control character).")
            }
            if shown.isEmpty {
                BTNote(ui: ui, text: "Nothing matches.")
            } else {
                VStack(spacing: 0) {
                    header
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ui.theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ui.theme.surfaceBorder))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            column("DEC", 30)
            column("HEX", 26)
            column("OCT", 30)
            column("BINARY", 62)
            column("CHAR", 34)
            Text("NAME")
                .font(ui.caption)
                .foregroundStyle(ui.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private func column(_ text: String, _ width: CGFloat) -> some View {
        Text(text)
            .font(ui.caption)
            .foregroundStyle(ui.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func row(_ entry: ASCIIEntry) -> some View {
        Button {
            BTClipboard.copy(entry.character ?? entry.hex)
        } label: {
            HStack(spacing: 8) {
                cell(String(entry.code), 30, ui.primary)
                cell(entry.hex, 26, ui.accent)
                cell(entry.octal, 30, ui.secondary)
                cell(entry.binary, 62, ui.secondary)
                Text(entry.glyph)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(entry.isControl ? ui.secondary : ui.primary)
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label(entry))
                        .font(.system(size: 11))
                        .foregroundStyle(ui.primary)
                        .lineLimit(1)
                    if let extra = detail(entry) {
                        Text(extra)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(ui.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ text: String, _ width: CGFloat, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
    }

    private func label(_ entry: ASCIIEntry) -> String {
        if let abbreviation = entry.abbreviation { return abbreviation + " · " + entry.description }
        return entry.description
    }

    private func detail(_ entry: ASCIIEntry) -> String? {
        var parts: [String] = []
        if let escape = entry.escape { parts.append("C: " + escape) }
        if let caret = entry.caret { parts.append(caret) }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }
}

// MARK: - Base64

struct Base64ToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.base64

    var body: some View {
        let isEncode = model.value(tool, "mode") == "encode"
        let urlSafe = model.value(tool, "variant") == "url"
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "Base64 packs 3 bytes (24 bits) into 4 printable characters of 6 bits each — that’s why encoded data grows by a third and ends in = padding.")
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: modeOptions)
                BTChoice(ui: ui, title: "Alphabet", selection: model.binding(tool, "variant"),
                         options: [("standard", "Standard + / (padded)"), ("url", "URL-safe - _ (no padding)")])
                if isEncode {
                    BTChoice(ui: ui, title: "Input is", selection: model.binding(tool, "kind"), options: kindOptions)
                }
                BTInput(ui: ui, title: isEncode ? "Input" : "Base64", text: model.binding(tool, "input"),
                        placeholder: isEncode ? "Hello world" : "SGVsbG8gd29ybGQ=", lines: 3)
            }
            if isEncode {
                encode(urlSafe: urlSafe)
            } else {
                decode()
            }
        }
    }

    @ViewBuilder
    private func encode(urlSafe: Bool) -> some View {
        switch btInputBytes(model.value(tool, "input"), kind: model.value(tool, "kind")) {
        case .failure(let problem):
            BTNote(ui: ui, text: problem.message, isProblem: true)
        case .success(let bytes):
            BTCard(ui: ui, title: "Output") {
                BTValueRow(ui: ui, label: "Base64", value: Base64Codec.encode(bytes, urlSafe: urlSafe, padded: !urlSafe), tint: ui.accent)
                BTNote(ui: ui, text: "\(bytes.count) byte\(bytes.count == 1 ? "" : "s") in, \(Base64Codec.encode(bytes, urlSafe: urlSafe, padded: !urlSafe).count) characters out.")
            }
            steps(bytes, urlSafe: urlSafe)
            HStack {
                BTSendMenu(ui: ui, from: .base64, bytes: bytes, model: model)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func decode() -> some View {
        switch Base64Codec.decode(model.value(tool, "input")) {
        case .failure(let problem):
            BTNote(ui: ui, text: problem.message, isProblem: true)
        case .success(let bytes):
            BTCard(ui: ui, title: "Decoded — \(bytes.count) byte\(bytes.count == 1 ? "" : "s")") {
                if ByteFormat.isValidUTF8(bytes) {
                    BTValueRow(ui: ui, label: "Text (UTF-8)", value: ByteFormat.utf8Text(bytes), tint: ui.accent)
                } else {
                    BTNote(ui: ui, text: "These bytes are not text (not valid UTF-8), so only the byte views are shown.")
                }
                BTValueRow(ui: ui, label: "Hex", value: ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
                BTValueRow(ui: ui, label: "Binary", value: ByteFormat.binary.encode(Array(bytes.prefix(64))))
            }
            HStack {
                BTSendMenu(ui: ui, from: .base64, bytes: bytes, model: model)
                Spacer()
            }
        }
    }

    private func steps(_ bytes: [UInt8], urlSafe: Bool) -> some View {
        let groups = Base64Steps.groups(bytes, urlSafe: urlSafe, padded: !urlSafe, limit: 24)
        return BTCard(ui: ui, title: "Step by step, three bytes at a time") {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                groupView(group)
            }
            if bytes.count > 72 {
                BTNote(ui: ui, text: "Showing the first 24 groups of \((bytes.count + 2) / 3).")
            }
        }
    }

    private func groupView(_ group: Base64Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(group.bytes.enumerated()), id: \.offset) { _, byte in
                    Text(BTByteChips.hex(byte))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ui.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ui.accent.opacity(0.16)))
                }
                Text(group.bitGroups.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ui.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(spacing: 14) {
                ForEach(Array(group.characters.enumerated()), id: \.offset) { position, character in
                    VStack(spacing: 1) {
                        Text(character)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(character == "=" ? ui.secondary : ui.primary)
                        Text(group.indices[position].map { String($0) } ?? "pad")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(ui.secondary)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.theme.background))
    }
}

// MARK: - Base32, Base58, Ascii85

struct BaseEncodingsToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.baseEncodings

    private var format: ByteFormat {
        ByteFormat(rawValue: model.value(tool, "format")) ?? .base32
    }

    var body: some View {
        let isEncode = model.value(tool, "mode") == "encode"
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, title: "Encoding", selection: model.binding(tool, "format"),
                         options: [("base32", "Base32"), ("base58", "Base58 (Bitcoin)"), ("ascii85", "Ascii85")])
                BTNote(ui: ui, text: note)
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: modeOptions)
                if isEncode {
                    BTChoice(ui: ui, title: "Input is", selection: model.binding(tool, "kind"), options: kindOptions)
                }
                BTInput(ui: ui, title: isEncode ? "Input" : format.title, text: model.binding(tool, "input"), placeholder: isEncode ? "Hello" : format.example, lines: 3)
            }
            if isEncode {
                switch btInputBytes(model.value(tool, "input"), kind: model.value(tool, "kind")) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                case .success(let bytes):
                    BTCard(ui: ui, title: "Output") {
                        BTValueRow(ui: ui, label: format.title, value: format.encode(bytes), tint: ui.accent)
                    }
                    send(bytes)
                }
            } else {
                switch format.decode(model.value(tool, "input")) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                case .success(let bytes):
                    BTCard(ui: ui, title: "Decoded — \(bytes.count) byte\(bytes.count == 1 ? "" : "s")") {
                        if ByteFormat.isValidUTF8(bytes) {
                            BTValueRow(ui: ui, label: "Text (UTF-8)", value: ByteFormat.utf8Text(bytes), tint: ui.accent)
                        }
                        BTValueRow(ui: ui, label: "Hex", value: ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
                    }
                    send(bytes)
                }
            }
        }
    }

    private var note: String {
        switch format {
        case .base58: return "Base58 drops the look-alike characters 0 O I l and the symbols + /, and keeps leading zero bytes as 1s. Bitcoin addresses use it."
        case .ascii85: return "Ascii85 turns 4 bytes into 5 characters (25% growth, against Base64’s 33%). A run of four zero bytes is a single z."
        default: return "Base32 uses A–Z and 2–7 in groups of 5 bits, padded with =. It survives case-insensitive systems, which is why one-time-password secrets use it."
        }
    }

    private func send(_ bytes: [UInt8]) -> some View {
        HStack {
            BTSendMenu(ui: ui, from: .baseEncodings, bytes: bytes, model: model)
            Spacer()
        }
    }
}

// MARK: - URL encoding

struct URLEncodingToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.urlEncoding

    private var allowed: PercentEncoding.Allowed {
        switch model.value(tool, "set") {
        case "strict", "form": return .unreserved
        case "uri": return .uri
        default: return .uriComponent
        }
    }

    var body: some View {
        let isEncode = model.value(tool, "mode") == "encode"
        let form = model.value(tool, "set") == "form"
        let input = model.value(tool, "input")
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: modeOptions)
                if isEncode {
                    BTChoice(ui: ui, title: "Leave these alone", selection: model.binding(tool, "set"),
                             options: [("strict", "Letters, digits - . _ ~"), ("component", "encodeURIComponent"), ("uri", "encodeURI (a whole URL)"), ("form", "Form: space → +")])
                }
                BTInput(ui: ui, title: isEncode ? "Text" : "Percent-encoded text", text: model.binding(tool, "input"),
                        placeholder: isEncode ? "name=Zoë & friends/100%" : "name%3DZo%C3%AB%20%26%20friends", lines: 3)
                BTNote(ui: ui, text: "Anything that is not safe in a URL becomes % and two hex digits of its UTF-8 bytes — so é (two bytes) becomes %C3%A9.")
            }
            if isEncode {
                let bytes = Array(input.utf8)
                BTCard(ui: ui, title: "Encoded") {
                    BTValueRow(ui: ui, label: "Result", value: PercentEncoding.encode(bytes, allowed: allowed, spaceAsPlus: form), tint: ui.accent)
                }
                breakdown(input, form: form)
                HStack {
                    BTSendMenu(ui: ui, from: .urlEncoding, bytes: bytes, model: model)
                    Spacer()
                }
            } else {
                switch PercentEncoding.decode(input, plusIsSpace: form) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                    BTChoice(ui: ui, selection: model.binding(tool, "set"), options: [("component", "Plain"), ("form", "Form: + is a space")])
                case .success(let bytes):
                    BTCard(ui: ui, title: "Decoded") {
                        BTValueRow(ui: ui, label: "Text", value: ByteFormat.utf8Text(bytes), tint: ui.accent)
                        BTChoice(ui: ui, selection: model.binding(tool, "set"), options: [("component", "Plain"), ("form", "Form: + is a space")])
                        if !ByteFormat.isValidUTF8(bytes) {
                            BTNote(ui: ui, text: "The bytes are not valid UTF-8 (a different text encoding, or binary data).", isProblem: true)
                        }
                    }
                    HStack {
                        BTSendMenu(ui: ui, from: .urlEncoding, bytes: bytes, model: model)
                        Spacer()
                    }
                }
            }
        }
    }

    private func breakdown(_ text: String, form: Bool) -> some View {
        let pieces = PercentBreakdown.pieces(of: text, allowed: allowed, spaceAsPlus: form)
        return BTCard(ui: ui, title: "Character by character") {
            FlowLayout(spacing: 4) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    VStack(spacing: 2) {
                        Text(piece.character == " " ? "␣" : piece.character)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(ui.primary)
                        Text(piece.changed ? piece.encoded : "·")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(piece.changed ? ui.accent : ui.secondary)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(piece.changed ? ui.accent.opacity(0.14) : ui.theme.surfaceHover))
                }
            }
        }
    }
}

// MARK: - URL anatomy

struct URLAnatomyToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.urlAnatomy

    var body: some View {
        let input = model.value(tool, "input")
        let anatomy = URLAnatomy.parse(input)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "Every part of a URL has a job. Type one and watch it split into scheme · userinfo · host · port · path · query · fragment (RFC 3986), each shown raw and percent-decoded.")
                BTInput(ui: ui, title: "URL", text: model.binding(tool, "input"), placeholder: "https://example.com/path?q=1#top", lines: 2)
            }
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                BTCard(ui: ui, title: "Parts") {
                    Text(coloredURL(anatomy))
                        .font(ui.monoLarge)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    partRows(anatomy)
                }
                if !anatomy.queryItems.isEmpty {
                    BTCard(ui: ui, title: "Query parameters") {
                        ForEach(Array(anatomy.queryItems.enumerated()), id: \.offset) { _, item in
                            queryRow(item)
                        }
                    }
                }
                ForEach(Array(anatomy.notes.enumerated()), id: \.offset) { _, note in
                    BTNote(ui: ui, text: "• " + note)
                }
                HStack {
                    BTSendMenu(ui: ui, from: .urlAnatomy, bytes: Array(input.utf8), model: model)
                    Spacer()
                }
            }
        }
    }

    private func color(for kind: URLAnatomy.PartKind) -> Color {
        switch kind {
        case .scheme: return Color(hex: 0xB07CFF)
        case .userinfo: return Color(hex: 0xF05D5E)
        case .host: return Color(hex: 0x22B8CF)
        case .port: return Color(hex: 0xF59F00)
        case .path: return Color(hex: 0x40C057)
        case .query: return Color(hex: 0x4C9AFF)
        case .fragment: return Color(hex: 0xE64980)
        }
    }

    private func coloredURL(_ anatomy: URLAnatomy) -> AttributedString {
        var output = AttributedString()
        for segment in anatomy.segments {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = segment.kind.map { color(for: $0) } ?? ui.secondary
            output += piece
        }
        return output
    }

    @ViewBuilder
    private func partRows(_ anatomy: URLAnatomy) -> some View {
        if let scheme = anatomy.scheme {
            partRow(.scheme, scheme, extra: nil)
        }
        if let userinfo = anatomy.userinfo {
            partRow(.userinfo, userinfo, extra: decodedIfDifferent(userinfo))
        }
        if let host = anatomy.host, !host.isEmpty {
            partRow(.host, host, extra: nil)
        }
        if let port = anatomy.port {
            partRow(.port, port.isEmpty ? "(empty)" : port, extra: nil)
        } else if let port = anatomy.effectivePort, anatomy.host != nil {
            partRow(.port, String(port), extra: "default for \(anatomy.scheme ?? "this scheme") — not written in the URL")
        }
        if !anatomy.path.isEmpty {
            partRow(.path, anatomy.path, extra: decodedIfDifferent(anatomy.path))
        }
        if let fragment = anatomy.fragment {
            partRow(.fragment, fragment, extra: decodedIfDifferent(fragment))
        }
    }

    private func decodedIfDifferent(_ raw: String) -> String? {
        let decoded = URLAnatomy.decodeComponent(raw)
        return decoded == raw ? nil : "decoded: " + decoded
    }

    private func partRow(_ kind: URLAnatomy.PartKind, _ value: String, extra: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            BTBadge(text: kind.rawValue.uppercased(), color: color(for: kind))
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(ui.mono)
                    .foregroundStyle(ui.primary)
                    .textSelection(.enabled)
                Text(extra ?? URLAnatomy.role(of: kind))
                    .font(.system(size: 10))
                    .foregroundStyle(ui.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func queryRow(_ item: URLAnatomy.QueryItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(item.name)
                    .font(ui.mono)
                    .foregroundStyle(color(for: .query))
                Text("=")
                    .font(ui.mono)
                    .foregroundStyle(ui.secondary)
                Text(item.value ?? "(no value)")
                    .font(ui.mono)
                    .foregroundStyle(ui.primary)
                    .textSelection(.enabled)
            }
            if let raw = item.rawValue, raw != item.value {
                Text("raw: " + raw)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ui.secondary)
            }
        }
    }
}

// MARK: - Punycode

struct PunycodeToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.punycode

    var body: some View {
        let input = model.value(tool, "input").trimmingCharacters(in: .whitespacesAndNewlines)
        let usesURL = input.contains("://")
        let domain = usesURL ? (URLAnatomy.parse(input).host ?? input) : input
        let labels = Punycode.labels(of: domain)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "Domain names can only hold ASCII on the wire. A name with other characters is written as xn-- and the Punycode of each label: münchen becomes xn--mnchen-3ya. Paste either form, or a whole URL.")
                BTInput(ui: ui, title: "Domain", text: model.binding(tool, "input"), placeholder: "münchen.de or xn--mnchen-3ya.de")
                if usesURL {
                    BTNote(ui: ui, text: "Using the host of that URL: \(domain)")
                }
            }
            if !domain.isEmpty {
                BTCard(ui: ui, title: "Result") {
                    BTValueRow(ui: ui, label: "ASCII — what DNS sees", value: Punycode.toASCII(domain), tint: ui.accent)
                    BTValueRow(ui: ui, label: "Unicode — what people see", value: Punycode.toUnicode(domain))
                }
                if labels.count > 1 || labels.contains(where: { $0.isInternationalised }) {
                    BTCard(ui: ui, title: "Label by label") {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                            labelRow(label)
                        }
                    }
                }
                if labels.contains(where: { Punycode.mixesScripts($0.unicode) }) {
                    BTNote(ui: ui, text: "A label mixes alphabets (for example a Cyrillic а among Latin letters). That is the shape of a look-alike (homograph) domain — check the Unicode form before trusting it.", isProblem: true)
                }
                HStack {
                    BTSendMenu(ui: ui, from: .punycode, bytes: Array(Punycode.toASCII(domain).utf8), model: model)
                    Spacer()
                }
            }
        }
    }

    private func labelRow(_ label: Punycode.Label) -> some View {
        HStack(spacing: 8) {
            Text(label.unicode)
                .font(ui.mono)
                .foregroundStyle(ui.primary)
            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(ui.secondary)
            Text(label.ascii)
                .font(ui.mono)
                .foregroundStyle(label.isInternationalised ? ui.accent : ui.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - HTML entities

struct HTMLEntitiesToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.htmlEntities

    var body: some View {
        let isEncode = model.value(tool, "mode") == "encode"
        let input = model.value(tool, "input")
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: modeOptions)
                if isEncode {
                    BTChoice(ui: ui, title: "Also escape", selection: model.binding(tool, "scope"),
                             options: [("ascii", "Everything outside ASCII"), ("minimal", "Only & < > \" '")])
                }
                BTInput(ui: ui, title: isEncode ? "Text" : "HTML", text: model.binding(tool, "input"),
                        placeholder: isEncode ? "<p>café & crème</p>" : "&lt;p&gt;caf&eacute; &amp; cr&#xE8;me&lt;/p&gt;", lines: 3)
                BTNote(ui: ui, text: "& < > \" ' are reserved in markup and become &amp; &lt; &gt; &quot; &#39;. Decoding also reads names like &eacute; and numbers like &#233; or &#xE9;.")
            }
            if isEncode {
                let output = HTMLEntityEncoder.encode(input, asciiOnly: model.value(tool, "scope") != "minimal")
                BTCard(ui: ui, title: "Encoded") {
                    BTValueRow(ui: ui, label: "HTML", value: output, tint: ui.accent)
                }
                HStack {
                    BTSendMenu(ui: ui, from: .htmlEntities, bytes: Array(output.utf8), model: model)
                    Spacer()
                }
            } else {
                let output = HTMLEntities.decode(input)
                BTCard(ui: ui, title: "Decoded") {
                    BTValueRow(ui: ui, label: "Text", value: output, tint: ui.accent)
                }
                HStack {
                    BTSendMenu(ui: ui, from: .htmlEntities, bytes: Array(output.utf8), model: model)
                    Spacer()
                }
            }
        }
    }
}
