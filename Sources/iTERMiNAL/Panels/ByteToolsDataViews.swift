import SwiftUI

private let dataKindOptions: [(value: String, title: String)] = [("text", "Text (UTF-8)"), ("hex", "Hex bytes")]

/// How many characters of input the dump-style tools format.
private let dataLimit = 20_000

// MARK: - Hexdump

struct HexdumpToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.hexdump

    var body: some View {
        let isDump = model.value(tool, "mode") == "dump"
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "The view every reverse engineer lives in: byte offset, the raw hex, and the printable ASCII alongside (non-printable bytes shown as a dot).")
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: [("dump", "Make a dump"), ("parse", "Read a dump")])
                if isDump {
                    BTChoice(ui: ui, title: "Input is", selection: model.binding(tool, "kind"), options: dataKindOptions)
                    BTChoice(ui: ui, title: "Layout", selection: model.binding(tool, "layout"),
                             options: HexDump.Layout.allCases.map { (value: $0.rawValue, title: $0.title) })
                    BTChoice(ui: ui, title: "Bytes per line", selection: model.binding(tool, "perLine"),
                             options: [("8", "8"), ("16", "16"), ("32", "32")])
                    BTChoice(ui: ui, title: "Hex letters", selection: model.binding(tool, "upper"), options: [("0", "abcdef"), ("1", "ABCDEF")])
                }
                BTInput(ui: ui, title: isDump ? "Input" : "Dump", text: model.binding(tool, "input"),
                        placeholder: isDump ? "Apex: the bytes are real." : "00000000  41 70 65 78  |Apex|", lines: isDump ? 3 : 6)
            }
            if isDump {
                dump()
            } else {
                read()
            }
        }
    }

    @ViewBuilder
    private func dump() -> some View {
        let input = String(model.value(tool, "input").prefix(dataLimit))
        switch btInputBytes(input, kind: model.value(tool, "kind")) {
        case .failure(let problem):
            BTNote(ui: ui, text: problem.message, isProblem: true)
        case .success(let bytes):
            let layout = HexDump.Layout(rawValue: model.value(tool, "layout")) ?? .canonical
            let perLine = Int(model.value(tool, "perLine")) ?? 16
            let upper = model.value(tool, "upper") == "1"
            let text = HexDump.format(bytes, layout: layout, perLine: perLine, uppercase: upper)
            BTCard(ui: ui, title: "\(bytes.count) byte\(bytes.count == 1 ? "" : "s")") {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(HexDump.rows(bytes, perLine: perLine).prefix(400).enumerated()), id: \.offset) { _, row in
                            rowView(row, perLine: perLine, upper: upper, layout: layout)
                        }
                    }
                    .padding(.bottom, 6)
                }
                HStack(spacing: 8) {
                    BTButton(ui: ui, title: "Copy dump", symbol: "doc.on.doc") { BTClipboard.copy(text) }
                    BTSendMenu(ui: ui, from: .hexdump, bytes: bytes, model: model)
                    Spacer()
                }
            }
        }
    }

    private func rowView(_ row: HexDump.Row, perLine: Int, upper: Bool, layout: HexDump.Layout) -> some View {
        HStack(spacing: 12) {
            Text(offsetText(row.offset, upper: upper))
                .foregroundStyle(ui.secondary)
            Text(hexText(row, perLine: perLine, upper: upper, layout: layout))
                .foregroundStyle(ui.primary)
            Text(row.ascii)
                .foregroundStyle(ui.accent)
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
    }

    private func offsetText(_ offset: Int, upper: Bool) -> String {
        let text = String(offset, radix: 16, uppercase: upper)
        return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }

    /// The hex column of a row, padded so the ASCII lines up.
    private func hexText(_ row: HexDump.Row, perLine: Int, upper: Bool, layout: HexDump.Layout) -> String {
        var out = ""
        for index in 0..<perLine {
            if index < row.bytes.count {
                out += BTByteChips.hex(row.bytes[index])
            } else {
                out += "  "
            }
            if layout == .xxd {
                if index % 2 == 1 { out += " " }
            } else {
                out += " "
                if index == 7 && perLine > 8 { out += " " }
            }
        }
        return upper ? out.uppercased() : out.lowercased()
    }

    @ViewBuilder
    private func read() -> some View {
        let input = String(model.value(tool, "input").prefix(dataLimit * 4))
        let bytes = HexDump.parse(input)
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BTNote(ui: ui, text: "Paste the output of hexdump -C, xxd, or plain hex — the offsets and the ASCII column are ignored.")
        } else if bytes.isEmpty {
            BTNote(ui: ui, text: "No hex bytes found in that.", isProblem: true)
        } else {
            BTCard(ui: ui, title: "\(bytes.count) byte\(bytes.count == 1 ? "" : "s") read") {
                BTValueRow(ui: ui, label: "Hex", value: ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: false)))
                BTValueRow(ui: ui, label: "Text", value: HexDump.asciiText(bytes))
                if ByteFormat.isValidUTF8(bytes) {
                    BTValueRow(ui: ui, label: "UTF-8", value: ByteFormat.utf8Text(bytes), tint: ui.accent)
                }
                BTValueRow(ui: ui, label: "Base64", value: Base64Codec.encode(bytes, urlSafe: false, padded: true))
            }
            HStack {
                BTSendMenu(ui: ui, from: .hexdump, bytes: bytes, model: model)
                Spacer()
            }
        }
    }
}

// MARK: - ASN.1 / DER

struct ASN1ToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.asn1

    var body: some View {
        let isParse = model.value(tool, "mode") == "parse"
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "ASN.1 DER is how certificates, keys and many protocols write structured data: a tag, a length, and a value — often more of the same inside.")
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: [("parse", "Read DER"), ("build", "Build DER")])
            }
            if isParse {
                parse()
            } else {
                build()
            }
        }
    }

    // MARK: Read

    @ViewBuilder
    private func parse() -> some View {
        let text = model.value(tool, "input")
        BTCard(ui: ui) {
            BTInput(ui: ui, title: "DER as hex, Base64 or PEM", text: model.binding(tool, "input"),
                    placeholder: "30 0A 02 01 05 06 05 2A 03 04 05 06   or   -----BEGIN CERTIFICATE-----", lines: 5)
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch ASN1.bytes(fromText: text) {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let bytes):
                switch ASN1.parse(bytes) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                case .success(let nodes):
                    tree(nodes, bytes: bytes)
                }
            }
        }
    }

    private func tree(_ nodes: [ASN1Node], bytes: [UInt8]) -> some View {
        let lines = ASN1.lines(nodes)
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "\(bytes.count) bytes · \(lines.count) element\(lines.count == 1 ? "" : "s")") {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lines.prefix(600).enumerated()), id: \.offset) { _, line in
                        lineView(line)
                    }
                }
                if lines.count > 600 {
                    BTNote(ui: ui, text: "Showing the first 600 elements.")
                }
                HStack(spacing: 8) {
                    BTButton(ui: ui, title: "Copy as text", symbol: "doc.on.doc") { BTClipboard.copy(plainText(lines)) }
                    BTSendMenu(ui: ui, from: .asn1, bytes: bytes, model: model)
                    Spacer()
                }
            }
        }
    }

    private func color(for name: String) -> Color {
        switch name {
        case "SEQUENCE", "SET": return Color(hex: 0x22B8CF)
        case "INTEGER", "ENUMERATED": return Color(hex: 0xF59F00)
        case "OBJECT IDENTIFIER": return Color(hex: 0xB07CFF)
        case "BOOLEAN", "NULL": return Color(hex: 0xE64980)
        case "BIT STRING", "OCTET STRING": return Color(hex: 0x868E96)
        case "UTCTime", "GeneralizedTime": return Color(hex: 0x4C9AFF)
        default: return name.hasPrefix("[") ? Color(hex: 0xF76707) : Color(hex: 0x40C057)
        }
    }

    private func lineView(_ line: ASN1.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(line.offset))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ui.secondary)
                .frame(width: 34, alignment: .trailing)
            Text(line.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(for: line.name))
            Text(line.summary.isEmpty ? "(\(line.length) bytes)" : line.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.summary.isEmpty ? ui.secondary : ui.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(line.depth, 10)) * 12)
    }

    private func plainText(_ lines: [ASN1.Line]) -> String {
        lines.map { line in
            String(repeating: "  ", count: line.depth) + "\(line.offset): \(line.name) (\(line.length))" + (line.summary.isEmpty ? "" : " " + line.summary)
        }.joined(separator: "\n")
    }

    // MARK: Build

    @ViewBuilder
    private func build() -> some View {
        let type = model.value(tool, "buildType")
        let wrap = model.value(tool, "wrap")
        BTCard(ui: ui) {
            BTChoice(ui: ui, title: "Element", selection: model.binding(tool, "buildType"),
                     options: ASN1.buildTypes.map { (value: $0.id, title: $0.title) })
            if type != "null" {
                BTInput(ui: ui, title: valueTitle(type), text: model.binding(tool, "buildValue"), placeholder: placeholder(type))
            }
            BTChoice(ui: ui, title: "Wrap in", selection: model.binding(tool, "wrap"),
                     options: [("none", "Nothing"), ("sequence", "SEQUENCE"), ("set", "SET")])
        }
        switch ASN1.build(type: type, value: model.value(tool, "buildValue")) {
        case .failure(let problem):
            BTNote(ui: ui, text: problem.message, isProblem: true)
        case .success(let element):
            let der = ASN1.wrap(element, as: wrap)
            BTCard(ui: ui, title: "DER — \(der.count) bytes") {
                BTValueRow(ui: ui, label: "Hex", value: ByteFormat.hex.encode(der, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)), tint: ui.accent,
                           onUse: { useAsInput(der) })
                BTValueRow(ui: ui, label: "Base64", value: Base64Codec.encode(der, urlSafe: false, padded: true))
                BTNote(ui: ui, text: "The first byte is the tag, the next the length (a long length uses several bytes), then the value.")
            }
            HStack {
                BTSendMenu(ui: ui, from: .asn1, bytes: der, model: model)
                Spacer()
            }
        }
    }

    private func useAsInput(_ der: [UInt8]) {
        model.set(tool, "input", to: ByteFormat.hex.encode(der, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
        model.set(tool, "mode", to: "parse")
    }

    private func valueTitle(_ type: String) -> String {
        switch type {
        case "integer": return "Number — decimal, 0x…, or negative"
        case "oid": return "Dotted numbers, or a name like rsaEncryption"
        case "boolean": return "true or false"
        case "octets", "bits": return "Hex bytes"
        default: return "Text"
        }
    }

    private func placeholder(_ type: String) -> String {
        switch type {
        case "integer": return "65537"
        case "oid": return "1.2.840.113549.1.1.1"
        case "boolean": return "true"
        case "octets", "bits": return "01 02 03"
        default: return "hello"
        }
    }
}

// MARK: - Hashes and checksums

struct HashesToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.hashes

    var body: some View {
        let compare = model.value(tool, "compare").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, title: "Input is", selection: model.binding(tool, "kind"), options: dataKindOptions)
                BTInput(ui: ui, title: "Input", text: model.binding(tool, "input"), placeholder: "Text, or hex bytes", lines: 3)
                BTInput(ui: ui, title: "Compare with (optional) — paste an expected hash", text: model.binding(tool, "compare"), placeholder: "e3b0c442…")
                BTInput(ui: ui, title: "HMAC key (optional)", text: model.binding(tool, "hmacKey"), placeholder: "Secret key")
                if !model.value(tool, "hmacKey").isEmpty {
                    BTChoice(ui: ui, title: "Key is", selection: model.binding(tool, "keyKind"), options: dataKindOptions)
                }
            }
            switch btInputBytes(model.value(tool, "input"), kind: model.value(tool, "kind")) {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let bytes):
                results(bytes, compare: compare)
            }
        }
    }

    @ViewBuilder
    private func results(_ bytes: [UInt8], compare: String) -> some View {
        let keyText = model.value(tool, "hmacKey")
        let key: [UInt8]? = keyText.isEmpty ? nil : btInputBytes(keyText, kind: model.value(tool, "keyKind")).successValue
        if !keyText.isEmpty && key == nil {
            BTNote(ui: ui, text: "The HMAC key is not valid hex.", isProblem: true)
        }
        BTCard(ui: ui, title: "\(bytes.count) byte\(bytes.count == 1 ? "" : "s") hashed") {
            ForEach(DigestAlgorithm.allCases.filter { $0.isCryptographic }) { algorithm in
                digestRow(algorithm, bytes: bytes, compare: compare, key: key)
            }
        }
        BTCard(ui: ui, title: "Checksums") {
            ForEach(DigestAlgorithm.allCases.filter { !$0.isCryptographic }) { algorithm in
                digestRow(algorithm, bytes: bytes, compare: compare, key: nil)
            }
            BTNote(ui: ui, text: "Checksums catch accidents (a flipped bit in transit) but are not secure: anyone can change data and fix the check value.")
        }
        HStack {
            BTSendMenu(ui: ui, from: .hashes, bytes: DigestAlgorithm.sha256.digest(bytes), model: model)
            Text("sends the SHA-256")
                .font(.system(size: 10))
                .foregroundStyle(ui.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func digestRow(_ algorithm: DigestAlgorithm, bytes: [UInt8], compare: String, key: [UInt8]?) -> some View {
        let useHMAC = key != nil && algorithm.supportsHMAC
        let digest: [UInt8] = useHMAC ? (algorithm.hmac(key: key ?? [], message: bytes) ?? []) : algorithm.digest(bytes)
        let hex = ByteFormat.hex.encode(digest, style: ByteStyle(delimiter: "", prefix: "", uppercase: false))
        let matches = !compare.isEmpty && (hex == compare || hex == compare.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: ""))
        VStack(alignment: .leading, spacing: 2) {
            BTValueRow(ui: ui, label: (useHMAC ? "HMAC-" : "") + algorithm.title + (matches ? "  ✓ matches" : ""), value: hex, tint: matches ? Color.green : nil)
            if let caution = algorithm.caution, algorithm.isCryptographic {
                Text(caution)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Result {
    /// The value of a success, or nil.
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

// MARK: - Timestamps

struct TimestampToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.timestamp

    private var unit: TimestampUnit? {
        switch model.value(tool, "unit") {
        case "s": return .seconds
        case "ms": return .milliseconds
        case "us": return .microseconds
        case "ns": return .nanoseconds
        default: return nil
        }
    }

    var body: some View {
        let text = model.value(tool, "input")
        let now = Date()
        // Nothing typed means "now", so the page is never empty.
        let effective = text.trimmingCharacters(in: .whitespaces).isEmpty ? String(Int64(now.timeIntervalSince1970)) : text
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Unix time or a date", text: model.binding(tool, "input"),
                        placeholder: "Empty means now — or 1700000000, 2023-11-14T22:13:20Z, 2023-11-14 22:13")
                BTChoice(ui: ui, title: "A number is in", selection: model.binding(tool, "unit"),
                         options: [("auto", "Guess"), ("s", "seconds"), ("ms", "milliseconds"), ("us", "microseconds"), ("ns", "nanoseconds")])
                HStack(spacing: 8) {
                    BTButton(ui: ui, title: "Now", symbol: "clock") {
                        model.set(tool, "input", to: String(Int64(Date().timeIntervalSince1970)))
                        model.set(tool, "unit", to: "s")
                    }
                    Spacer()
                }
            }
            switch Timestamps.parse(effective, unit: unit) {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let parsed):
                BTCard(ui: ui, title: parsed.unit.map { "Read as \($0.title)" } ?? "Read as a date") {
                    ForEach(Array(Timestamps.rows(for: parsed.instant, timeZone: .current, now: now).enumerated()), id: \.offset) { _, row in
                        BTValueRow(ui: ui, label: row.label, value: row.value, tint: row.label == "ISO 8601 (UTC)" ? ui.accent : nil)
                    }
                }
                HStack {
                    BTSendMenu(ui: ui, from: .timestamp, bytes: bytes(parsed.instant), model: model)
                    Spacer()
                }
            }
        }
    }

    private func bytes(_ instant: Instant) -> [UInt8] {
        BigNumber(UInt64(max(0, instant.seconds))).toBytes()
    }
}

// MARK: - UUID

struct UUIDToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.uuid

    var body: some View {
        let text = model.value(tool, "input")
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "UUID", text: model.binding(tool, "input"), placeholder: "f81d4fae-7dec-11d0-a765-00a0c91e6bf6 — any spelling")
                HStack(spacing: 8) {
                    BTButton(ui: ui, title: "New random (v4)", symbol: "dice") {
                        model.set(tool, "input", to: UUIDInfo.random().canonical)
                    }
                    BTButton(ui: ui, title: "New time-ordered (v7)", symbol: "clock") {
                        model.set(tool, "input", to: UUIDInfo.timeOrdered(at: Date()).canonical)
                    }
                }
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                BTNote(ui: ui, text: "Make one with a button, or paste one to take it apart: its version, variant, and — for the time-based kinds — when it was made.")
            } else {
                switch UUIDInfo.parse(text) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                case .success(let info):
                    details(info)
                }
            }
        }
        .onAppear {
            if model.value(tool, "input").isEmpty {
                model.set(tool, "input", to: UUIDInfo.random().canonical)
            }
        }
    }

    private func details(_ info: UUIDInfo) -> some View {
        let compact = info.canonical.replacingOccurrences(of: "-", with: "")
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "What it is") {
                BTValueRow(ui: ui, label: "Kind", value: info.isNil ? "the nil UUID (all zeros)" : info.isMax ? "the max UUID (all ones)" : info.versionName, tint: ui.accent)
                BTValueRow(ui: ui, label: "Variant", value: info.variant)
                if let instant = info.timestamp {
                    BTValueRow(ui: ui, label: "Made at (UTC)", value: Timestamps.rows(for: instant, timeZone: .current, now: Date()).first(where: { $0.label == "ISO 8601 (UTC)" })?.value ?? "")
                }
                if let node = info.node {
                    BTValueRow(ui: ui, label: "Node (often a MAC address)", value: node)
                }
            }
            BTCard(ui: ui, title: "Spellings") {
                BTValueRow(ui: ui, label: "Standard", value: info.canonical)
                BTValueRow(ui: ui, label: "Upper case", value: info.canonical.uppercased())
                BTValueRow(ui: ui, label: "No dashes", value: compact)
                BTValueRow(ui: ui, label: "Braces (Microsoft)", value: "{" + info.canonical.uppercased() + "}")
                BTValueRow(ui: ui, label: "URN", value: "urn:uuid:" + info.canonical)
                BTValueRow(ui: ui, label: "Base64", value: Base64Codec.encode(info.bytes, urlSafe: false, padded: true))
                BTValueRow(ui: ui, label: "Bytes", value: ByteFormat.hex.encode(info.bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)))
            }
            HStack {
                BTSendMenu(ui: ui, from: .uuid, bytes: info.bytes, model: model)
                Spacer()
            }
        }
    }
}

// MARK: - JWT

struct JWTToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.jwt

    var body: some View {
        let token = model.value(tool, "input")
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Token", text: model.binding(tool, "input"), placeholder: "eyJhbGciOiJIUzI1NiIs…", lines: 5)
                BTInput(ui: ui, title: "Secret (HS256, HS384, HS512 only) — stays in this window", text: model.binding(tool, "secret"), placeholder: "your-256-bit-secret")
            }
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                BTNote(ui: ui, text: "Paste a JSON Web Token to read its header, claims and signature.")
            } else {
                switch JWT.decode(token) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                case .success(let info):
                    decoded(info)
                }
            }
        }
    }

    private func decoded(_ info: JWTInfo) -> some View {
        let secret = model.value(tool, "secret")
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "Signature") {
                signatureStatus(info, secret: secret)
                BTValueRow(ui: ui, label: "Algorithm", value: info.algorithm ?? "(none stated)")
                BTValueRow(ui: ui, label: "Signature (hex)", value: ByteFormat.hex.encode(info.signature, style: ByteStyle(delimiter: "", prefix: "", uppercase: false)))
            }
            if !info.claims.isEmpty {
                BTCard(ui: ui, title: "Claims") {
                    ForEach(Array(info.claims.enumerated()), id: \.offset) { _, claim in
                        claimRow(claim)
                    }
                }
            }
            BTCard(ui: ui, title: "Header") {
                BTValueRow(ui: ui, label: "JSON", value: info.headerJSON)
            }
            BTCard(ui: ui, title: "Payload") {
                BTValueRow(ui: ui, label: "JSON", value: info.payloadJSON)
            }
            BTNote(ui: ui, text: "Anyone can read a token’s contents. Decoding is not trusting: only a verified signature, from a key you control, says it is genuine.")
            HStack {
                BTSendMenu(ui: ui, from: .jwt, bytes: Array(info.payloadJSON.utf8), model: model)
                Text("sends the payload")
                    .font(.system(size: 10))
                    .foregroundStyle(ui.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func signatureStatus(_ info: JWTInfo, secret: String) -> some View {
        if secret.isEmpty {
            BTNote(ui: ui, text: "Not checked — type the secret above to verify an HS256, HS384 or HS512 signature.")
        } else if let valid = JWT.verify(info, secret: Array(secret.utf8)) {
            Text(valid ? "✓ Signature is valid for that secret" : "✗ Signature does not match that secret")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(valid ? Color.green : Color.red)
        } else {
            BTNote(ui: ui, text: "This algorithm (\(info.algorithm ?? "none")) needs a public key or has no signature, which this tool does not check.")
        }
    }

    private func claimRow(_ claim: JWTInfo.Claim) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(claim.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ui.accent)
                    .frame(width: 56, alignment: .leading)
                Text(claim.value)
                    .font(ui.mono)
                    .foregroundStyle(ui.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = claim.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(note.hasPrefix("expired") || note.hasPrefix("not yet") ? Color.orange : ui.secondary)
                    .padding(.leading, 64)
            }
        }
    }
}

// MARK: - XOR and ciphers

struct XORCiphersToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.xorCiphers

    var body: some View {
        let mode = model.value(tool, "mode")
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, title: "Operation", selection: model.binding(tool, "mode"),
                         options: [("xor", "XOR"), ("caesar", "Caesar / ROT13"), ("rot47", "ROT47"), ("atbash", "Atbash"),
                                   ("vigenere", "Vigenère"), ("break", "Break single-byte XOR")])
                if mode == "xor" || mode == "break" {
                    BTChoice(ui: ui, title: "Input is", selection: model.binding(tool, "kind"), options: dataKindOptions)
                }
                BTInput(ui: ui, title: "Input", text: model.binding(tool, "input"), placeholder: "Hello, world", lines: 3)
                keyFields(mode)
            }
            switch mode {
            case "xor": xorResult()
            case "break": breakResult()
            default: textResult(mode)
            }
        }
    }

    @ViewBuilder
    private func keyFields(_ mode: String) -> some View {
        switch mode {
        case "xor":
            BTInput(ui: ui, title: "Key (repeats along the input)", text: model.binding(tool, "key"), placeholder: "key")
            BTChoice(ui: ui, title: "Key is", selection: model.binding(tool, "keyKind"), options: dataKindOptions)
        case "caesar":
            BTInput(ui: ui, title: "Shift (13 is ROT13; use a negative number to undo)", text: model.binding(tool, "shift"), placeholder: "13")
        case "vigenere":
            BTInput(ui: ui, title: "Key (letters)", text: model.binding(tool, "key"), placeholder: "lemon")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func xorResult() -> some View {
        let kind = model.value(tool, "kind")
        switch btInputBytes(model.value(tool, "input"), kind: kind) {
        case .failure(let problem):
            BTNote(ui: ui, text: problem.message, isProblem: true)
        case .success(let data):
            switch btInputBytes(model.value(tool, "key"), kind: model.value(tool, "keyKind")) {
            case .failure(let problem):
                BTNote(ui: ui, text: "Key: " + problem.message, isProblem: true)
            case .success(let key):
                let out = Ciphers.xor(data, key: key)
                BTCard(ui: ui, title: "\(out.count) bytes") {
                    BTValueRow(ui: ui, label: "Hex", value: ByteFormat.hex.encode(out, style: ByteStyle(delimiter: " ", prefix: "", uppercase: false)), tint: ui.accent,
                               onUse: { useAsInput(out) })
                    BTValueRow(ui: ui, label: "Text", value: HexDump.asciiText(out))
                    BTValueRow(ui: ui, label: "Base64", value: Base64Codec.encode(out, urlSafe: false, padded: true))
                    BTNote(ui: ui, text: "XOR is its own undo: apply the same key to the result to get the input back.")
                }
                HStack {
                    BTSendMenu(ui: ui, from: .xorCiphers, bytes: out, model: model)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func breakResult() -> some View {
        switch btInputBytes(model.value(tool, "input"), kind: model.value(tool, "kind")) {
        case .failure(let problem):
            BTNote(ui: ui, text: problem.message, isProblem: true)
        case .success(let data):
            let guesses = Ciphers.singleByteXORGuesses(data, count: 6)
            if guesses.isEmpty {
                BTNote(ui: ui, text: "Type or paste the bytes to try every one-byte key on.")
            } else {
                BTCard(ui: ui, title: "Best guesses of 256 keys, most English-looking first") {
                    ForEach(Array(guesses.enumerated()), id: \.offset) { _, guess in
                        BTValueRow(ui: ui, label: "Key 0x" + BTByteChips.hex(guess.key) + " (\(guess.key))", value: guess.text, tint: guess.key == guesses.first?.key ? ui.accent : nil)
                    }
                    BTNote(ui: ui, text: "Works when the whole message was XORed with one repeated byte. Short messages and non-English text rank less reliably.")
                }
            }
        }
    }

    @ViewBuilder
    private func textResult(_ mode: String) -> some View {
        let input = model.value(tool, "input")
        let out: String = {
            switch mode {
            case "caesar": return Ciphers.caesar(input, shift: Int(model.value(tool, "shift").trimmingCharacters(in: .whitespaces)) ?? 13)
            case "rot47": return Ciphers.rot47(input)
            case "atbash": return Ciphers.atbash(input)
            default: return Ciphers.vigenere(input, key: model.value(tool, "key"), decrypt: false)
            }
        }()
        BTCard(ui: ui, title: "Result") {
            BTValueRow(ui: ui, label: mode == "vigenere" ? "Encrypted" : "Result", value: out, tint: ui.accent, onUse: { model.set(tool, "input", to: out) })
            if mode == "vigenere" {
                BTValueRow(ui: ui, label: "Decrypted (treating the input as ciphertext)", value: Ciphers.vigenere(input, key: model.value(tool, "key"), decrypt: true))
            }
            if mode == "caesar" {
                BTNote(ui: ui, text: "Shift 13 (ROT13) is its own undo. Only letters move; case, digits and punctuation stay.")
            }
        }
        HStack {
            BTSendMenu(ui: ui, from: .xorCiphers, bytes: Array(out.utf8), model: model)
            Spacer()
        }
    }

    private func useAsInput(_ bytes: [UInt8]) {
        model.set(tool, "input", to: ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: false)))
        model.set(tool, "kind", to: "hex")
    }
}

// MARK: - Morse code

struct MorseToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.morse

    var body: some View {
        let isEncode = model.value(tool, "mode") == "encode"
        let input = model.value(tool, "input")
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTChoice(ui: ui, selection: model.binding(tool, "mode"), options: [("encode", "Text → Morse"), ("decode", "Morse → text")])
                BTInput(ui: ui, title: isEncode ? "Text" : "Morse (dots and dashes; space between letters, / between words)", text: model.binding(tool, "input"),
                        placeholder: isEncode ? "SOS" : "... --- ...", lines: 2)
            }
            if isEncode {
                let morse = Morse.encode(input)
                BTCard(ui: ui, title: "Morse") {
                    BTValueRow(ui: ui, label: "Code", value: morse, tint: ui.accent, onUse: { useAsInput(morse) })
                    glyphs(input)
                }
                HStack {
                    BTSendMenu(ui: ui, from: .morse, bytes: Array(morse.utf8), model: model)
                    Spacer()
                }
            } else {
                let text = Morse.decode(input)
                BTCard(ui: ui, title: "Text") {
                    BTValueRow(ui: ui, label: "Decoded", value: text, tint: ui.accent)
                    if text.contains("?") {
                        BTNote(ui: ui, text: "A ? stands for a group of dots and dashes that is not a letter.")
                    }
                }
                HStack {
                    BTSendMenu(ui: ui, from: .morse, bytes: Array(text.utf8), model: model)
                    Spacer()
                }
            }
        }
    }

    private func useAsInput(_ morse: String) {
        model.set(tool, "input", to: morse)
        model.set(tool, "mode", to: "decode")
    }

    /// Each letter with its dots and dashes drawn.
    private func glyphs(_ text: String) -> some View {
        let letters = Array(text.uppercased().filter { $0 != " " && $0 != "\n" }.prefix(60))
        return FlowLayout(spacing: 8) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                let code = Morse.encode(String(letter))
                if !code.isEmpty {
                    VStack(spacing: 4) {
                        Text(String(letter))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ui.primary)
                        HStack(spacing: 3) {
                            ForEach(Array(code.enumerated()), id: \.offset) { _, mark in
                                if mark == "." {
                                    Circle().fill(ui.accent).frame(width: 6, height: 6)
                                } else {
                                    Capsule().fill(ui.accent).frame(width: 16, height: 6)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ui.theme.background))
                }
            }
        }
    }
}

// MARK: - Byte order

struct ByteOrderToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.byteOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "Big-endian writes the most significant byte first (network order); little-endian writes it last (x86 and Apple Silicon). The same four bytes are two different numbers.")
                BTInput(ui: ui, title: "Hex bytes (1, 2, 4 or 8 for the numeric readings)", text: model.binding(tool, "input"), placeholder: "12 34 56 78")
            }
            switch ByteFormat.hex.decode(model.value(tool, "input")) {
            case .failure(let problem):
                BTNote(ui: ui, text: problem.message, isProblem: true)
            case .success(let bytes):
                if bytes.isEmpty {
                    BTNote(ui: ui, text: "Type some bytes.")
                } else {
                    results(bytes)
                }
            }
        }
    }

    private func results(_ bytes: [UInt8]) -> some View {
        let swapped = ByteOrderTool.swapped(bytes)
        let readings = ByteOrderTool.readings(bytes)
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "Byte for byte") {
                VStack(alignment: .leading, spacing: 4) {
                    BTLabel(ui: ui, text: "As typed")
                    BTByteChips(ui: ui, bytes: bytes, tint: ui.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    BTLabel(ui: ui, text: "Reversed")
                    BTByteChips(ui: ui, bytes: swapped, tint: Color.orange)
                }
                BTValueRow(ui: ui, label: "Reversed (hex)", value: ByteFormat.hex.encode(swapped, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)),
                           onUse: { model.set(tool, "input", to: ByteFormat.hex.encode(swapped, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true))) })
            }
            if readings.isEmpty {
                BTNote(ui: ui, text: "\(bytes.count) bytes: numeric readings are for 1, 2, 4 or 8 bytes.")
            } else {
                BTCard(ui: ui, title: "Read as a number") {
                    ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                        BTValueRow(ui: ui, label: reading.label, value: reading.value)
                    }
                }
            }
            HStack(spacing: 8) {
                BTSendMenu(ui: ui, from: .byteOrder, bytes: swapped, model: model)
                Text("sends the reversed bytes")
                    .font(.system(size: 10))
                    .foregroundStyle(ui.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - Data sizes

struct SizesToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.sizes

    var body: some View {
        let unitSymbol = model.value(tool, "unit")
        let unit = SizeUnits.units.first(where: { $0.symbol == unitSymbol }) ?? SizeUnits.units[1]
        let typed = model.value(tool, "input").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "").trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTInput(ui: ui, title: "Amount", text: model.binding(tool, "input"), placeholder: "1")
                BTChoice(ui: ui, title: "Unit", selection: model.binding(tool, "unit"),
                         options: SizeUnits.units.map { (value: $0.symbol, title: $0.symbol) })
                BTNote(ui: ui, text: "KB, MB, GB are powers of 1000 (what drive makers and networks use); KiB, MiB, GiB are powers of 1024 (what memory and many operating systems report). That gap is why a “1 TB” drive shows as about 931 GiB.")
            }
            if let value = Double(typed), value.isFinite {
                BTCard(ui: ui, title: "\(typed) \(unit.symbol) is") {
                    ForEach(Array(SizeUnits.convert(value, from: unit).enumerated()), id: \.offset) { _, entry in
                        BTValueRow(ui: ui, label: entry.unit.name + " (" + entry.unit.symbol + ")", value: entry.text, tint: entry.unit == unit ? ui.accent : nil)
                    }
                }
            } else {
                BTNote(ui: ui, text: "Type a number.", isProblem: !typed.isEmpty)
            }
        }
    }
}

// MARK: - IP address and CIDR

struct IPAddressToolView: View {
    @ObservedObject var model: ByteToolsModel
    let ui: BTStyle

    private let tool = ByteTool.ipAddress

    var body: some View {
        let text = model.value(tool, "input")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui) {
                BTNote(ui: ui, text: "An IPv4 address is 32 bits, an IPv6 address 128. Type one in any form — dotted, a whole number, 0x hex, IPv6 with :: — and add /24 (or a netmask) to see its network.")
                BTInput(ui: ui, title: "Address, or address/prefix", text: model.binding(tool, "input"),
                        placeholder: "192.168.1.10/24 · 2001:db8::1 · 3232235777")
            }
            if trimmed.isEmpty {
                BTNote(ui: ui, text: "Type an IP address.")
            } else {
                switch IPTools.parseSubnet(trimmed) {
                case .failure(let problem):
                    BTNote(ui: ui, text: problem.message, isProblem: true)
                case .success(let subnet):
                    details(subnet, hasPrefix: trimmed.contains("/") || trimmed.contains(" "))
                }
            }
        }
    }

    private func details(_ subnet: IPTools.Subnet, hasPrefix: Bool) -> some View {
        let address = subnet.address
        return VStack(alignment: .leading, spacing: 12) {
            BTCard(ui: ui, title: "IPv\(address.version) address") {
                BTValueRow(ui: ui, label: "Address", value: address.text, tint: ui.accent)
                BTValueRow(ui: ui, label: "Kind", value: address.kind)
                if !address.isV4 {
                    BTValueRow(ui: ui, label: "Fully written", value: address.expanded)
                }
                BTValueRow(ui: ui, label: "As a number", value: address.integer)
                BTValueRow(ui: ui, label: "Hex", value: address.hex)
                BTValueRow(ui: ui, label: "Binary", value: address.binary)
                if let mapped = address.asMappedIPv6 {
                    BTValueRow(ui: ui, label: "As IPv6 (IPv4-mapped)", value: mapped)
                }
                if let inner = address.mappedIPv4 {
                    BTValueRow(ui: ui, label: "The IPv4 inside", value: inner.dotted)
                }
                BTValueRow(ui: ui, label: "Reverse DNS (PTR) name", value: address.reverseName)
            }
            if hasPrefix {
                network(subnet)
            }
            HStack {
                BTSendMenu(ui: ui, from: .ipAddress, bytes: address.bytes, model: model)
                Spacer()
            }
        }
    }

    private func network(_ subnet: IPTools.Subnet) -> some View {
        let range = subnet.hostRange
        return BTCard(ui: ui, title: "Network /\(subnet.prefix)") {
            if subnet.address.isV4 {
                BTBitRows(
                    ui: ui,
                    bits: BitPattern(width: 32, value: UInt64(subnet.address.bytes.reduce(0) { ($0 << 8) | UInt32($1) })).bits,
                    perRow: 8,
                    cell: 24,
                    tint: { index in index >= 32 - subnet.prefix ? ui.accent : Color.orange },
                    caption: nil,
                    onToggle: nil
                )
                BTNote(ui: ui, text: "Set bits are blue where they belong to the network (the first \(subnet.prefix)) and orange where they belong to the host.")
            }
            BTValueRow(ui: ui, label: "Netmask", value: subnet.mask.text)
            BTValueRow(ui: ui, label: "Wildcard", value: subnet.wildcard.text)
            BTValueRow(ui: ui, label: "Network address", value: subnet.network.text, tint: ui.accent)
            BTValueRow(ui: ui, label: subnet.address.isV4 ? "Broadcast address" : "Last address", value: subnet.last.text)
            BTValueRow(ui: ui, label: "First host", value: range.first.text)
            BTValueRow(ui: ui, label: "Last host", value: range.last.text)
            BTValueRow(ui: ui, label: "Addresses in the network", value: subnet.total.toString(base: 10))
            BTValueRow(ui: ui, label: "Usable by hosts", value: subnet.usableHosts)
        }
    }
}
