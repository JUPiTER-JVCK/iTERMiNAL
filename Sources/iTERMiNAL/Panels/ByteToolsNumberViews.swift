import SwiftUI

// MARK: - Shared helpers

extension BitPattern {
    /// `0x7F`, padded to the width.
    var hexText: String {
        let digits = String(unsigned, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, width / 4 - digits.count)) + digits
    }

    /// The bits in groups of four.
    var binaryText: String {
        let digits = String(unsigned, radix: 2)
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        return DigitGrouping.group(padded, size: 4, separator: " ")
    }

    var octalText: String { "0o" + String(unsigned, radix: 8) }
}

/// The bits a number would be at `width`: exact when it fits, and cut to the
/// low bits when it does not, so the switches still show something while the
/// field says it is too big.
func lenientBitPattern(_ parsed: Result<ParsedInteger, ByteFormatProblem>, width: Int) -> BitPattern {
    switch parsed {
    case .failure:
        return BitPattern(width: width, value: 0)
    case .success(let number):
        if case .success(let exact) = BitPattern.from(number, width: width) { return exact }
        var low: UInt64 = 0
        if let exact = number.magnitude.asUInt64 {
            low = exact
        } else {
            for byte in number.magnitude.toBytes().suffix(8) {
                low = low << 8 | UInt64(byte)
            }
        }
        return BitPattern(width: width, value: number.isNegative ? (~low) &+ 1 : low)
    }
}

private let widthOptions: [(value: String, title: String)] = [("8", "8-bit"), ("16", "16-bit"), ("32", "32-bit"), ("64", "64-bit")]

// MARK: - Binary / Decimal / Hex / Octal

/// One number, written in the four bases people use, whichever you type it in.
struct NumberBaseToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle
    let tool: ByteTool
    let base: Int

    var body: some View {
        let parsed = IntegerInput.parse(model.value(tool, "input"), defaultBase: base)
        let grouped = model.value(tool, "grouped") == "1"
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "\(baseName) number", text: model.binding(tool, "input"), placeholder: placeholder)
                BTChoice(ui: ui, selection: model.binding(tool, "grouped"), options: [("1", "Grouped digits"), ("0", "Plain")])
                BTNote(ui: ui, text: hint)
            }
            switch parsed {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let number):
                results(number, grouped: grouped)
            }
        }
    }

    private var baseName: String {
        switch base {
        case 2: return "Binary"
        case 8: return "Octal"
        case 16: return "Hex"
        default: return "Decimal"
        }
    }

    private var placeholder: String {
        switch base {
        case 2: return "1010 0101"
        case 8: return "377"
        case 16: return "DEADBEEF"
        default: return "255"
        }
    }

    private var hint: String {
        switch base {
        case 2: return "Only 0 and 1. Any length — spaces and _ are ignored. A leading 0x, 0o or - works too."
        case 8: return "Digits 0–7: the base of Unix file permissions (755 = rwxr-xr-x)."
        case 16: return "Digits 0–9 and A–F, upper or lower case. 0x is optional. Any length."
        default: return "Any size of whole number, with a minus sign if you like. 0x, 0b and 0o prefixes switch base."
        }
    }

    private func results(_ number: ParsedInteger, grouped: Bool) -> some View {
        let bytes = number.magnitude.toBytes()
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "The same number in every base") {
                row("Binary · 2", 2, number, grouped)
                row("Octal · 8", 8, number, grouped)
                row("Decimal · 10", 10, number, grouped)
                row("Hex · 16", 16, number, grouped)
            }
            BTCard(ui: ui, title: "Size") {
                BTValueRow(ui: ui, label: "Bits needed", value: String(number.magnitude.bitLength))
                BTValueRow(ui: ui, label: "Bytes (big-endian)", value: "\(bytes.count) · " + ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
                if let value = number.magnitude.asUInt64, number.magnitude.bitLength > 0 {
                    BTBitRows(ui: ui, bits: bitsOf(value, bitLength: number.magnitude.bitLength), perRow: 8, cell: 26, tint: { _ in ui.accent }, caption: nil, onToggle: nil)
                }
                if number.isNegative {
                    BTNote(ui: ui, text: "Shown for the magnitude. For the bits of a negative number at a fixed width, use Two's Complement.")
                }
            }
            HStack {
                BTSendMenu(ui: ui, from: tool, bytes: bytes, model: model)
                Spacer()
            }
        }
    }

    private func row(_ label: String, _ rowBase: Int, _ number: ParsedInteger, _ grouped: Bool) -> some View {
        BTValueRow(
            ui: ui,
            label: label,
            value: NumberText.text(number, base: rowBase, grouped: grouped),
            tint: rowBase == base ? ui.accent : nil
        )
    }

    private func bitsOf(_ value: UInt64, bitLength: Int) -> [Bool] {
        let width = max(8, ((bitLength + 7) / 8) * 8)
        return (0..<width).reversed().map { (value >> UInt64($0)) & 1 == 1 }
    }
}

// MARK: - Base converter

struct BaseConverterToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    @State private var showAll = false

    private var fromBase: Int { Int(model.value(.baseN, "from")) ?? 10 }
    private var toBase: Int { Int(model.value(.baseN, "to")) ?? 16 }

    var body: some View {
        let parsed = IntegerInput.parse(model.value(.baseN, "input"), defaultBase: fromBase, allowPrefixes: false)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Number", text: model.binding(.baseN, "input"), placeholder: "Digits in the base below")
                HStack(spacing: 8) {
                    basePicker(title: "From", field: "from")
                    Button {
                        swap(parsed)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ui.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(ui.theme.surfaceHover))
                    }
                    .buttonStyle(.plain)
                    .help("Swap the bases, keeping the number")
                    .accessibilityLabel("Swap the two bases")
                    basePicker(title: "To", field: "to")
                    Spacer(minLength: 0)
                }
                BTChoice(ui: ui, title: "Common bases", selection: model.binding(.baseN, "to"), options: [("2", "2"), ("8", "8"), ("10", "10"), ("16", "16"), ("32", "32"), ("36", "36")])
                BTNote(ui: ui, text: "Digits past 9 are the letters A–Z (A = 10 … Z = 35), either case.")
            }
            switch parsed {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let number):
                BTCard(ui: ui, title: "Base \(fromBase) → base \(toBase)") {
                    BTValueRow(ui: ui, label: "Result", value: NumberText.text(number, base: toBase, grouped: false), tint: ui.accent)
                    BTValueRow(ui: ui, label: "Decimal", value: NumberText.text(number, base: 10, grouped: true))
                }
                allBases(number)
                HStack {
                    BTSendMenu(ui: ui, from: .baseN, bytes: number.magnitude.toBytes(), model: model)
                    Spacer()
                }
            }
        }
    }

    private func basePicker(title: String, field: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            BTLabel(ui: ui, text: title)
            Picker("", selection: model.binding(.baseN, field)) {
                ForEach(2...36, id: \.self) { value in
                    Text("base \(value)").tag(String(value))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func swap(_ parsed: Result<ParsedInteger, ByteFormatProblem>) {
        guard case .success(let number) = parsed else { return }
        let converted = NumberText.text(number, base: toBase, grouped: false)
        model.set(.baseN, "input", to: converted)
        model.set(.baseN, "from", to: String(toBase))
        model.set(.baseN, "to", to: String(fromBase))
    }

    private func allBases(_ number: ParsedInteger) -> some View {
        DisclosureGroup(isExpanded: $showAll) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(2...36, id: \.self) { value in
                    BTValueRow(ui: ui, label: "Base \(value)", value: NumberText.text(number, base: value, grouped: false))
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Every base from 2 to 36")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ui.primary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ui.theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ui.theme.surfaceBorder))
    }
}

// MARK: - Bits & bytes, and two's complement

/// A number as switches. One view serves two tools: Bits & Bytes leads with the
/// unsigned reading, Two's Complement with the signed one and how negation works.
struct BitEditorToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle
    let tool: ByteTool

    private var isTwos: Bool { tool == .twosComplement }

    var body: some View {
        let width = Int(model.value(tool, "width")) ?? 8
        let parsed = IntegerInput.parse(model.value(tool, "input"))
        let pattern = lenientBitPattern(parsed, width: width)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(
                    ui: ui,
                    title: isTwos ? "Number — decimal, or 0x… / 0b…" : "Number",
                    text: model.binding(tool, "input"),
                    placeholder: isTwos ? "-5" : "127"
                )
                BTChoice(ui: ui, title: "Width", selection: model.binding(tool, "width"), options: widthOptions)
            }
            if case .failure(let problem) = parsed {
                BTNote(ui: ui, text: problem.message, isProblem: true)
            } else if case .success(let number) = parsed, case .failure(let problem) = BitPattern.from(number, width: width) {
                BTNote(ui: ui, text: problem.message + " Showing the low \(width) bits.", isProblem: true)
            }
            BTCard(ui: ui, title: "Bits — click to flip") {
                BTBitRows(
                    ui: ui,
                    bits: pattern.bits,
                    perRow: 8,
                    cell: width <= 32 ? 32 : 28,
                    tint: { index in index == width - 1 ? Color.orange : ui.accent },
                    caption: captionProvider(width: width),
                    onToggle: { index in commit(pattern.flipping(index)) }
                )
                BTNote(ui: ui, text: pattern.isNegative
                    ? "Top bit 1 → negative when read as signed. Highest bit is on the left."
                    : "Top bit 0 → positive. Highest bit is on the left.")
            }
            if isTwos { negationCard(pattern) }
            readings(pattern)
            HStack {
                BTSendMenu(ui: ui, from: tool, bytes: pattern.bytes, model: model)
                Spacer()
            }
        }
    }

    private func captionProvider(width: Int) -> ((Int) -> String?)? {
        if width > 16 { return nil }
        return { index in weight(of: index, width: width) }
    }

    private func weight(of index: Int, width: Int) -> String? {
        if isTwos && index == width - 1 { return "−" + String(UInt64(1) << UInt64(index)) }
        return String(UInt64(1) << UInt64(index))
    }

    private func commit(_ pattern: BitPattern) {
        model.set(tool, "input", to: isTwos ? String(pattern.signed) : String(pattern.unsigned))
    }

    private func readings(_ pattern: BitPattern) -> some View {
        BTCard(ui: ui, title: "Reads as") {
            if isTwos {
                BTValueRow(ui: ui, label: "Signed (two's complement)", value: String(pattern.signed), tint: ui.accent)
                BTValueRow(ui: ui, label: "Unsigned", value: String(pattern.unsigned))
            } else {
                BTValueRow(ui: ui, label: "Decimal", value: String(pattern.unsigned), tint: ui.accent)
            }
            BTValueRow(ui: ui, label: "Hex", value: pattern.hexText)
            BTValueRow(ui: ui, label: "Octal", value: pattern.octalText)
            BTValueRow(ui: ui, label: "Binary", value: pattern.binaryText)
            if !isTwos && pattern.isNegative {
                BTValueRow(ui: ui, label: "As signed", value: String(pattern.signed))
            }
            let range = BitPattern.signedRange(width: pattern.width)
            BTNote(ui: ui, text: "\(pattern.width) bits hold \(range.min) to \(range.max) signed, or 0 to \(BitPattern.unsignedMax(width: pattern.width)) unsigned.")
        }
    }

    private func negationCard(_ pattern: BitPattern) -> some View {
        BTCard(ui: ui, title: "How negation works") {
            BTValueRow(ui: ui, label: "Bits", value: pattern.binaryText)
            BTValueRow(ui: ui, label: "Flip every bit (~)", value: pattern.inverted.binaryText)
            BTValueRow(ui: ui, label: "Add 1 → the negative", value: pattern.negated.binaryText + "  =  " + String(pattern.negated.signed), tint: ui.accent)
            FlowLayout(spacing: 6) {
                BTButton(ui: ui, title: "Invert", symbol: "circle.lefthalf.filled") { commit(pattern.inverted) }
                BTButton(ui: ui, title: "Negate", symbol: "plusminus") { commit(pattern.negated) }
                BTButton(ui: ui, title: "+ 1", symbol: nil) { commit(BitPattern(width: pattern.width, value: pattern.unsigned &+ 1)) }
                BTButton(ui: ui, title: "− 1", symbol: nil) { commit(BitPattern(width: pattern.width, value: pattern.unsigned &- 1)) }
            }
        }
    }
}

// MARK: - Bitwise calculator

struct BitwiseToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private var operation: BitwiseOperation {
        BitwiseOperation(rawValue: model.value(.bitwise, "op")) ?? .and
    }

    var body: some View {
        let width = Int(model.value(.bitwise, "width")) ?? 8
        let op = operation
        let a = lenientBitPattern(IntegerInput.parse(model.value(.bitwise, "a")), width: width)
        let b = lenientBitPattern(IntegerInput.parse(model.value(.bitwise, "b")), width: width)
        let result = op.apply(a, b)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, title: "Operation", selection: model.binding(.bitwise, "op"),
                         options: BitwiseOperation.allCases.map { (value: $0.rawValue, title: $0.title) })
                BTChoice(ui: ui, title: "Width", selection: model.binding(.bitwise, "width"), options: widthOptions)
                BTInput(ui: ui, title: "A — decimal, 0x…, 0b…", text: model.binding(.bitwise, "a"), placeholder: "0xCA")
                if !op.isUnary {
                    BTInput(ui: ui, title: op.secondIsCount ? "Places (n)" : "B — decimal, 0x…, 0b…", text: model.binding(.bitwise, "b"), placeholder: op.secondIsCount ? "3" : "0xA6")
                }
                BTNote(ui: ui, text: op.explanation)
                problemNote(model.value(.bitwise, "a"), name: "A", width: width)
                if !op.isUnary { problemNote(model.value(.bitwise, "b"), name: op.secondIsCount ? "Places" : "B", width: width) }
            }
            BTCard(ui: ui, title: "Bit by bit") {
                bitRow(label: "A", pattern: a, color: Color.blue)
                if !op.isUnary && !op.secondIsCount { bitRow(label: "B", pattern: b, color: Color.purple) }
                bitRow(label: resultLabel(op), pattern: result, color: ui.accent)
            }
            BTCard(ui: ui, title: "Result") {
                BTValueRow(ui: ui, label: "Unsigned", value: String(result.unsigned), tint: ui.accent)
                BTValueRow(ui: ui, label: "Signed", value: String(result.signed))
                BTValueRow(ui: ui, label: "Hex", value: result.hexText)
                BTValueRow(ui: ui, label: "Binary", value: result.binaryText)
            }
            HStack {
                BTSendMenu(ui: ui, from: .bitwise, bytes: result.bytes, model: model)
                Spacer()
            }
        }
    }

    private func resultLabel(_ op: BitwiseOperation) -> String {
        if op.isUnary { return op.symbol + "A" }
        return "A " + op.symbol + (op.secondIsCount ? " n" : " B")
    }

    @ViewBuilder
    private func problemNote(_ text: String, name: String, width: Int) -> some View {
        switch IntegerInput.parse(text) {
        case .failure(let problem):
            BTNote(ui: ui, text: "\(name): " + problem.message, isProblem: true)
        case .success(let number):
            if case .failure(let problem) = BitPattern.from(number, width: width) {
                BTNote(ui: ui, text: "\(name): " + problem.message, isProblem: true)
            }
        }
    }

    private func bitRow(label: String, pattern: BitPattern, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(ui.secondary)
            BTBitRows(
                ui: ui,
                bits: pattern.bits,
                perRow: pattern.width <= 16 ? pattern.width : 16,
                cell: pattern.width <= 8 ? 28 : 18,
                tint: { _ in color },
                caption: nil,
                onToggle: nil
            )
        }
    }
}

// MARK: - IEEE 754

struct FloatToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private var signColor: Color { Color(hex: 0xE5484D) }
    private var exponentColor: Color { Color(hex: 0x22B8CF) }
    private var mantissaColor: Color { Color(hex: 0x37B24D) }

    var body: some View {
        let format = FloatFormat(rawValue: Int(model.value(.float, "format")) ?? 32) ?? .single
        let text = model.value(.float, "input")
        let parsed = FloatBits.parse(text, format: format)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "A number, or its bits as 0x…", text: model.binding(.float, "input"), placeholder: "0.1")
                BTChoice(ui: ui, title: "Format", selection: model.binding(.float, "format"),
                         options: FloatFormat.allCases.map { (value: String($0.rawValue), title: $0.title) })
                examples
            }
            switch parsed {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let float):
                breakdown(float, typed: text)
            }
        }
    }

    private var examples: some View {
        FlowLayout(spacing: 6) {
            ForEach(["0.1", "1", "-2.5", "3.14159", "1e10", "-0", "inf", "nan"], id: \.self) { example in
                Button {
                    model.set(.float, "input", to: example)
                } label: {
                    Text(example)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ui.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(ui.theme.surfaceHover))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tint(for float: FloatBits) -> (Int) -> Color {
        let mantissaBits = float.format.mantissaBits
        let top = float.format.totalBits - 1
        return { index in
            if index == top { return signColor }
            if index >= mantissaBits { return exponentColor }
            return mantissaColor
        }
    }

    private func breakdown(_ float: FloatBits, typed: String) -> some View {
        let format = float.format
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "\(format.totalBits) bits — click to flip") {
                BTBitRows(
                    ui: ui,
                    bits: float.bitList,
                    perRow: 16,
                    cell: 18,
                    tint: tint(for: float),
                    caption: nil,
                    onToggle: { index in model.set(.float, "input", to: float.flipping(index).hex) }
                )
                FlowLayout(spacing: 12) {
                    legend("sign = \(float.isNegative ? "1 (−)" : "0 (+)")", color: signColor)
                    legend("exponent = \(float.exponentField)" + exponentSuffix(float), color: exponentColor)
                    legend("mantissa (\(format.mantissaBits) bits)", color: mantissaColor)
                }
            }
            BTCard(ui: ui, title: "What is stored") {
                if !typed.lowercased().hasPrefix("0x"), let exact = Double(typed.trimmingCharacters(in: .whitespaces)) {
                    BTValueRow(ui: ui, label: "You typed", value: typed.trimmingCharacters(in: .whitespaces))
                    BTValueRow(ui: ui, label: "Stored as", value: float.storedText, tint: ui.accent)
                    if let error = float.error(from: exact), error != 0 {
                        BTValueRow(ui: ui, label: "Rounding error", value: "\(error)")
                    }
                } else {
                    BTValueRow(ui: ui, label: "Value", value: float.storedText, tint: ui.accent)
                }
                BTValueRow(ui: ui, label: "Raw hex", value: float.hex)
                BTValueRow(ui: ui, label: "Kind", value: kindText(float))
                if let formula = formulaText(float) {
                    BTValueRow(ui: ui, label: "Formula", value: formula)
                }
            }
            BTCard(ui: ui, title: "This format") {
                let limits = FloatBits.limits(format)
                BTValueRow(ui: ui, label: "Largest finite", value: "\(limits.maxFinite)")
                BTValueRow(ui: ui, label: "Smallest normal", value: "\(limits.minNormal)")
                BTNote(ui: ui, text: "\(format.exponentBits) exponent bits (bias \(format.bias)) and \(format.mantissaBits) mantissa bits: about \(exactDigits(format)) decimal digits are exact.")
            }
            HStack {
                BTSendMenu(ui: ui, from: .float, bytes: BitPattern(width: format.totalBits, value: float.bits).bytes, model: model)
                Spacer()
            }
        }
    }

    private func exactDigits(_ format: FloatFormat) -> Int {
        switch format {
        case .half: return 3
        case .single: return 7
        case .double: return 15
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ui.primary)
        }
    }

    private func exponentSuffix(_ float: FloatBits) -> String {
        switch float.category {
        case .normal: return " − \(float.format.bias) = \(float.unbiasedExponent)"
        case .zero, .subnormal: return " (subnormal: \(float.unbiasedExponent))"
        case .infinity, .nan: return " (all ones)"
        }
    }

    private func kindText(_ float: FloatBits) -> String {
        switch float.category {
        case .zero: return float.isNegative ? "Negative zero" : "Zero"
        case .subnormal: return "Subnormal — no hidden 1, less precision"
        case .normal: return "Normal number"
        case .infinity: return float.isNegative ? "Negative infinity" : "Infinity"
        case .nan: return float.isQuietNaN ? "NaN (quiet)" : "NaN (signalling)"
        }
    }

    private func formulaText(_ float: FloatBits) -> String? {
        let scale = Double(UInt64(1) << UInt64(float.format.mantissaBits))
        let fraction = Double(float.mantissaField) / scale
        let sign = float.isNegative ? "−" : "+"
        switch float.category {
        case .normal: return "\(sign)\(1 + fraction) × 2^\(float.unbiasedExponent)"
        case .subnormal: return "\(sign)\(fraction) × 2^\(float.unbiasedExponent)"
        default: return nil
        }
    }
}

// MARK: - Varint and ZigZag

struct VarintToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            encodeCard
            decodeCard
        }
    }

    // MARK: Number → bytes

    @ViewBuilder
    private var encodeCard: some View {
        let parsed = IntegerInput.parse(model.value(.varint, "input"))
        BTCard(ui: ui, title: "Number → bytes") {
            BTInput(ui: ui, title: "Number", text: model.binding(.varint, "input"), placeholder: "300 or -2")
            switch parsed {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let number):
                encoded(number)
            }
        }
    }

    @ViewBuilder
    private func encoded(_ number: ParsedInteger) -> some View {
        let signed: Int64? = signedValue(number)
        let unsigned: UInt64? = number.isNegative ? nil : number.magnitude.asUInt64
        if let unsigned {
            let bytes = Varint.encode(unsigned)
            block(title: "Unsigned varint (uint32 / uint64)", bytes: bytes, tint: ui.accent)
        }
        if let signed {
            let zigzag = Varint.zigzag(signed)
            BTValueRow(ui: ui, label: "ZigZag of \(signed)", value: "\(zigzag)  =  " + BitPattern(width: 64, value: zigzag).hexText)
            block(title: "ZigZag varint (sint32 / sint64)", bytes: Varint.encode(zigzag), tint: Color.green)
            if signed < 0 {
                block(title: "Negative as plain int64 (always 10 bytes)", bytes: Varint.encode(UInt64(bitPattern: signed)), tint: Color.orange)
            }
        }
        if signed == nil && unsigned == nil {
            BTNote(ui: ui, text: "That does not fit in 64 bits, which is as large as a varint here goes.", isProblem: true)
        }
    }

    private func signedValue(_ number: ParsedInteger) -> Int64? {
        guard let magnitude = number.magnitude.asUInt64 else { return nil }
        if number.isNegative {
            return magnitude <= UInt64(1) << 63 ? Int64(truncatingIfNeeded: (~magnitude) &+ 1) : nil
        }
        return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
    }

    private func block(title: String, bytes: [UInt8], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BTLabel(ui: ui, text: title)
            VarintBytesView(ui: ui, bytes: bytes, tint: tint)
            HStack(spacing: 8) {
                Text(ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
                    .font(ui.monoLarge)
                    .foregroundStyle(ui.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                BTSendMenu(ui: ui, from: .varint, bytes: bytes, model: model)
            }
        }
    }

    // MARK: Bytes → numbers

    @ViewBuilder
    private var decodeCard: some View {
        let text = model.value(.varint, "hex")
        BTCard(ui: ui, title: "Bytes → numbers") {
            BTInput(ui: ui, title: "Hex bytes", text: model.binding(.varint, "hex"), placeholder: "AC 02")
            switch ByteFormat.hex.decode(text) {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let bytes):
                decoded(bytes)
            }
        }
    }

    @ViewBuilder
    private func decoded(_ bytes: [UInt8]) -> some View {
        let all = Varint.decodeAll(bytes)
        if bytes.isEmpty {
            BTNote(ui: ui, text: "Type the bytes of one or more varints.")
        } else {
            VarintBytesView(ui: ui, bytes: bytes, tint: ui.accent)
            ForEach(Array(all.values.enumerated()), id: \.offset) { index, value in
                BTValueRow(
                    ui: ui,
                    label: all.values.count > 1 ? "Number \(index + 1)" : "Number",
                    value: "\(value)  ·  ZigZag-decoded \(Varint.unzigzag(value))"
                )
            }
            if all.leftover > 0 {
                BTNote(ui: ui, text: all.values.isEmpty
                    ? "These bytes do not make a varint: the last byte still has its top bit set, or it runs past ten bytes."
                    : "\(all.leftover) byte\(all.leftover == 1 ? "" : "s") at the end are not a whole varint.", isProblem: true)
            }
        }
    }
}

/// Each byte of a varint, with its continuation bit apart from its seven payload bits.
struct VarintBytesView: View {
    let ui: BTStyle
    let bytes: [UInt8]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(Varint.groups(Array(bytes.prefix(64))).enumerated()), id: \.offset) { _, group in
                VStack(spacing: 2) {
                    Text(BTByteChips.hex(group.byte))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                    HStack(spacing: 3) {
                        Text(group.continues ? "1" : "0")
                            .foregroundStyle(group.continues ? Color.orange : ui.secondary)
                        Text(payloadBits(group.payload))
                            .foregroundStyle(ui.primary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            }
        }
    }

    private func payloadBits(_ payload: UInt8) -> String {
        let text = String(payload, radix: 2)
        return String(repeating: "0", count: max(0, 7 - text.count)) + text
    }
}
