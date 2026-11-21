import Foundation

// MARK: - Timestamps

/// A moment, held as whole seconds and nanoseconds since 1970-01-01 UTC, so
/// that a nanosecond count survives the trip: a Double cannot hold one.
struct Instant: Equatable {
    var seconds: Int64
    /// 0 ..< 1_000_000_000, always counted forward from `seconds`.
    var nanos: Int

    init(seconds: Int64, nanos: Int = 0) {
        var s = seconds
        var n = nanos
        if n < 0 || n >= 1_000_000_000 {
            let carry = Int64((n >= 0 ? n : n - 999_999_999) / 1_000_000_000)
            s += carry
            n -= Int(carry) * 1_000_000_000
        }
        self.seconds = s
        self.nanos = n
    }

    init(date: Date) {
        let whole = date.timeIntervalSince1970.rounded(.down)
        self.init(seconds: Int64(whole), nanos: min(999_999_999, Int(((date.timeIntervalSince1970 - whole) * 1e9).rounded())))
    }

    var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9) }

    /// Total in the given unit, or nil if that does not fit in 64 bits.
    func total(in unit: TimestampUnit) -> Int64? {
        let perSecond = unit.perSecond
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: perSecond)
        if overflow { return nil }
        let (sum, overflow2) = scaled.addingReportingOverflow(Int64(nanos) / (1_000_000_000 / perSecond))
        return overflow2 ? nil : sum
    }
}

enum TimestampUnit: Int, CaseIterable, Identifiable {
    case seconds = 1, milliseconds = 1_000, microseconds = 1_000_000, nanoseconds = 1_000_000_000

    var id: Int { rawValue }
    var perSecond: Int64 { Int64(rawValue) }

    var title: String {
        switch self {
        case .seconds: return "seconds"
        case .milliseconds: return "milliseconds"
        case .microseconds: return "microseconds"
        case .nanoseconds: return "nanoseconds"
        }
    }

    var short: String {
        switch self {
        case .seconds: return "s"
        case .milliseconds: return "ms"
        case .microseconds: return "µs"
        case .nanoseconds: return "ns"
        }
    }

    /// The unit a bare number most likely is, by its size: 10 digits is seconds,
    /// 13 milliseconds, 16 microseconds, 19 nanoseconds.
    static func guess(forDigits digits: Int) -> TimestampUnit {
        switch digits {
        case ..<12: return .seconds
        case 12..<15: return .milliseconds
        case 15..<18: return .microseconds
        default: return .nanoseconds
        }
    }
}

enum Timestamps {
    /// A number of seconds/ms/µs/ns (a fractional part is allowed) or a date.
    /// The unit is guessed from the length unless one is given.
    static func parse(_ text: String, unit: TimestampUnit?) -> Result<(instant: Instant, unit: TimestampUnit?), ByteFormatProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ByteFormatProblem(message: "Type a Unix time or a date.")) }

        var body = trimmed
        var negative = false
        if body.hasPrefix("-") {
            negative = true
            body.removeFirst()
        }
        let numeric = body.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        if !numeric.isEmpty, parts.count <= 2, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }), !parts[0].isEmpty {
            let whole = String(parts[0])
            let used = unit ?? TimestampUnit.guess(forDigits: whole.count)
            guard let integer = Int64(whole) else { return .failure(ByteFormatProblem(message: "That number is too large for a time.")) }
            // The digits after a point are a fraction of one unit, and a unit is 1e9 / perSecond nanoseconds.
            let unitNanos = 1_000_000_000 / Int(used.perSecond)
            let fractionDigits = String(unitNanos).count - 1
            let fractionText = String((parts.count == 2 ? String(parts[1]) : "").prefix(fractionDigits))
            let fractionNanos = Int(fractionText.padding(toLength: fractionDigits, withPad: "0", startingAt: 0)) ?? 0
            let secondsPart = integer / used.perSecond
            let nanos = Int(integer % used.perSecond) * unitNanos + fractionNanos
            let signed = negative ? Instant(seconds: -secondsPart, nanos: -nanos) : Instant(seconds: secondsPart, nanos: nanos)
            return .success((signed, used))
        }
        if let instant = parseCivil(trimmed) ?? parseRFC2822(trimmed) { return .success((instant, nil)) }
        return .failure(ByteFormatProblem(message: "Not a number or a date I can read. Try 1700000000, 2023-11-14T22:13:20Z or 2023-11-14 22:13:20."))
    }

    /// `2023-11-14`, `2023-11-14 22:13:20`, `2023-11-14T22:13:20.123456789Z`, `…+05:30`, with `/` or `-` in the
    /// date. No zone means UTC. Done by hand so the answer is exact to the nanosecond and the same on every
    /// system, which the system's own formatters are not.
    static func parseCivil(_ text: String) -> Instant? {
        let pattern = #"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T ]+(\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?)?\s*(Z|z|UTC|GMT|[+-]\d{2}(?::?\d{2})?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard let year = Int(group(1) ?? ""), let month = Int(group(2) ?? ""), let day = Int(group(3) ?? "") else { return nil }
        let hour = Int(group(4) ?? "0") ?? 0
        let minute = Int(group(5) ?? "0") ?? 0
        let second = Int(group(6) ?? "0") ?? 0
        guard (1...12).contains(month), (1...daysInMonth(year, month)).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var nanos = 0
        if let fraction = group(7) { nanos = Int(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0 }
        var offset = 0
        if let zone = group(8), let sign = zone.first, sign == "+" || sign == "-" {
            let digits = zone.dropFirst().filter { $0 != ":" }
            let zh = Int(digits.prefix(2)) ?? 0
            let zm = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 0 : 0
            offset = (sign == "-" ? -1 : 1) * (zh * 3600 + zm * 60)
        }
        let days = Int64(daysFromCivil(year, month, day))
        return Instant(seconds: days * 86_400 + Int64(hour * 3600 + minute * 60 + second - offset), nanos: nanos)
    }

    private static func parseRFC2822(_ text: String) -> Instant? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text).map { Instant(date: $0) }
    }

    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to the given date in the proleptic Gregorian calendar.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// `instant` written every way the tool shows, for `timeZone` as "local".
    static func rows(for instant: Instant, timeZone: TimeZone, now: Date) -> [Row] {
        var rows: [Row] = []
        for unit in TimestampUnit.allCases {
            rows.append(Row(label: "Unix \(unit.title)", value: instant.total(in: unit).map(String.init) ?? "out of range"))
        }
        let date = instant.date
        rows.append(Row(label: "ISO 8601 (UTC)", value: format(date, "yyyy-MM-dd'T'HH:mm:ss", suffix: "'Z'", UTC: true, fractional: instant.nanos)))
        rows.append(Row(label: "Local (\(timeZone.abbreviation(for: date) ?? timeZone.identifier))",
                        value: format(date, "yyyy-MM-dd HH:mm:ss", suffix: " xxx", timeZone: timeZone, fractional: instant.nanos)))
        rows.append(Row(label: "RFC 2822", value: format(date, "EEE, dd MMM yyyy HH:mm:ss 'GMT'", UTC: true, fractional: 0)))
        rows.append(Row(label: "Day of week", value: format(date, "EEEE", UTC: true, fractional: 0)))
        rows.append(Row(label: "Relative", value: relative(from: instant.date, to: now)))
        let filetime = (Double(instant.seconds) + 11_644_473_600) * 1e7
        rows.append(Row(label: "Windows FILETIME", value: filetime >= 0 && filetime < 9e18 ? String(Int64(filetime) + Int64(instant.nanos / 100)) : "out of range"))
        let ticks = (Double(instant.seconds) + 62_135_596_800) * 1e7
        rows.append(Row(label: ".NET ticks", value: ticks >= 0 && ticks < 9e18 ? String(Int64(ticks) + Int64(instant.nanos / 100)) : "out of range"))
        rows.append(Row(label: "Apple absolute (2001)", value: String(Double(instant.seconds - 978_307_200) + Double(instant.nanos) / 1e9)))
        rows.append(Row(label: "Excel serial", value: String(Double(instant.seconds) / 86_400 + 25_569)))
        if (0...Int64(UInt32.max)).contains(instant.seconds) {
            rows.append(Row(label: "32-bit hex", value: "0x" + hex8(UInt64(instant.seconds))))
        }
        return rows
    }

    private static func hex8(_ value: UInt64) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }

    /// `date` written with `pattern`, then any fractional seconds, then `suffix` (a zone, usually):
    /// the fraction goes between because a zone offset has colons of its own to be confused with.
    private static func format(_ date: Date, _ pattern: String, suffix: String = "", UTC: Bool = false, timeZone: TimeZone? = nil, fractional: Int) -> String {
        func formatter(_ pattern: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = UTC ? TimeZone(identifier: "UTC") : (timeZone ?? .current)
            formatter.dateFormat = pattern
            return formatter
        }
        var text = formatter(pattern).string(from: date)
        if fractional > 0 {
            var digits = String(fractional)
            digits = String(repeating: "0", count: 9 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        if !suffix.isEmpty { text += formatter(suffix).string(from: date) }
        return text
    }

    /// "3 days ago", "in 2 hours": a plain sentence for the distance from `now`.
    static func relative(from date: Date, to now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let seconds = Int(abs(delta).rounded())
        let (value, unit): (Int, String)
        switch seconds {
        case ..<60: (value, unit) = (seconds, "second")
        case ..<3600: (value, unit) = (seconds / 60, "minute")
        case ..<86_400: (value, unit) = (seconds / 3600, "hour")
        case ..<2_592_000: (value, unit) = (seconds / 86_400, "day")
        case ..<31_536_000: (value, unit) = (seconds / 2_592_000, "month")
        default: (value, unit) = (seconds / 31_536_000, "year")
        }
        if seconds < 2 { return "now" }
        let phrase = "\(value) \(unit)\(value == 1 ? "" : "s")"
        return delta >= 0 ? "in \(phrase)" : "\(phrase) ago"
    }
}

// MARK: - UUIDs

struct UUIDInfo: Equatable {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Reads a UUID in any common spelling: with or without dashes, in braces, or `urn:uuid:`.
    static func parse(_ text: String) -> Result<UUIDInfo, ByteFormatProblem> {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("urn:uuid:") { body.removeFirst(9) }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        body = body.replacingOccurrences(of: "-", with: "")
        guard body.count == 32 else {
            return .failure(ByteFormatProblem(message: "A UUID is 32 hex digits (36 with dashes); this has \(body.count)."))
        }
        guard case .success(let bytes) = ByteFormat.decodeHex(body), let info = UUIDInfo(bytes: bytes) else {
            return .failure(ByteFormatProblem(message: "A UUID holds only the hex digits 0–9 and a–f."))
        }
        return .success(info)
    }

    var canonical: String {
        let hex = ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: "", prefix: "", uppercase: false))
        let chars = Array(hex)
        func part(_ range: Range<Int>) -> String { String(chars[range]) }
        return [part(0..<8), part(8..<12), part(12..<16), part(16..<20), part(20..<32)].joined(separator: "-")
    }

    var isNil: Bool { bytes.allSatisfy { $0 == 0 } }
    var isMax: Bool { bytes.allSatisfy { $0 == 0xFF } }
    var version: Int { Int(bytes[6] >> 4) }

    var variant: String {
        switch bytes[8] >> 5 {
        case 0, 1, 2, 3: return "NCS (reserved, backward-compatible)"
        case 4, 5: return "RFC 4122 / RFC 9562 (the standard one)"
        case 6: return "Microsoft (reserved)"
        default: return "reserved for the future"
        }
    }

    var isStandardVariant: Bool { bytes[8] >> 6 == 0b10 }

    var versionName: String {
        guard isStandardVariant else { return "not a standard UUID" }
        switch version {
        case 1: return "version 1 — time and node"
        case 2: return "version 2 — DCE security"
        case 3: return "version 3 — name, MD5"
        case 4: return "version 4 — random"
        case 5: return "version 5 — name, SHA-1"
        case 6: return "version 6 — reordered time"
        case 7: return "version 7 — Unix time and random"
        case 8: return "version 8 — custom"
        default: return "version \(version)"
        }
    }

    /// When a time-based UUID (1, 6 or 7) was made.
    var timestamp: Instant? {
        guard isStandardVariant else { return nil }
        func be(_ range: Range<Int>) -> UInt64 { bytes[range].reduce(0) { $0 << 8 | UInt64($1) } }
        switch version {
        case 1, 6:
            let ticks: UInt64
            if version == 1 {
                ticks = (be(6..<8) & 0x0FFF) << 48 | be(4..<6) << 32 | be(0..<4)
            } else {
                ticks = be(0..<4) << 28 | be(4..<6) << 12 | (be(6..<8) & 0x0FFF)
            }
            // 100 ns ticks since 1582-10-15.
            let seconds = Int64(ticks / 10_000_000) - 12_219_292_800
            return Instant(seconds: seconds, nanos: Int(ticks % 10_000_000) * 100)
        case 7:
            let ms = be(0..<6)
            return Instant(seconds: Int64(ms / 1000), nanos: Int(ms % 1000) * 1_000_000)
        default:
            return nil
        }
    }

    /// The node (a MAC address, usually) of a version 1 UUID.
    var node: String? {
        guard isStandardVariant, version == 1 else { return nil }
        return ByteFormat.hex.encode(Array(bytes[10..<16]), style: ByteStyle(delimiter: ":", prefix: "", uppercase: false))
    }

    /// A random (version 4) UUID.
    static func random() -> UUIDInfo {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        bytes[6] = bytes[6] & 0x0F | 0x40
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUIDInfo(bytes: bytes)!
    }

    /// A time-ordered (version 7) UUID for `date`: 48 bits of Unix milliseconds, then random.
    static func timeOrdered(at date: Date) -> UUIDInfo {
        var generator = SystemRandomNumberGenerator()
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var bytes = (0..<6).reversed().map { UInt8(truncatingIfNeeded: ms >> UInt64($0 * 8)) }
        bytes += (0..<10).map { _ in UInt8.random(in: 0...255, using: &generator) }
        bytes[6] = bytes[6] & 0x0F | 0x70
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUIDInfo(bytes: bytes)!
    }
}

// MARK: - JSON Web Tokens

struct JWTInfo {
    struct Claim: Equatable {
        let name: String
        let value: String
        /// What the value means, such as the date an `exp` stands for.
        let note: String?
    }

    let headerJSON: String
    let payloadJSON: String
    let algorithm: String?
    let signature: [UInt8]
    let signingInput: [UInt8]
    let claims: [Claim]
}

enum JWT {
    static func decode(_ token: String, now: Date = Date()) -> Result<JWTInfo, ByteFormatProblem> {
        var text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("bearer ") { text.removeFirst(7) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            return .failure(ByteFormatProblem(message: "A JWT is three parts separated by dots; this has \(parts.count)."))
        }
        guard case .success(let headerBytes) = Base64Codec.decode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: Data(headerBytes)) as? [String: Any] else {
            return .failure(ByteFormatProblem(message: "The first part is not Base64URL-encoded JSON."))
        }
        guard case .success(let payloadBytes) = Base64Codec.decode(parts[1]) else {
            return .failure(ByteFormatProblem(message: "The second part is not Base64URL."))
        }
        let payloadObject = try? JSONSerialization.jsonObject(with: Data(payloadBytes))
        let payloadText: String
        var claims: [JWTInfo.Claim] = []
        if let payload = payloadObject as? [String: Any] {
            payloadText = pretty(payload)
            claims = claimList(payload, now: now)
        } else {
            payloadText = ByteFormat.utf8Text(payloadBytes)
        }
        guard case .success(let signature) = parts[2].isEmpty ? .success([UInt8]()) : Base64Codec.decode(parts[2]) else {
            return .failure(ByteFormatProblem(message: "The signature is not Base64URL."))
        }
        return .success(JWTInfo(
            headerJSON: pretty(header), payloadJSON: payloadText, algorithm: header["alg"] as? String,
            signature: signature, signingInput: Array((parts[0] + "." + parts[1]).utf8), claims: claims
        ))
    }

    private static func pretty(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "\(object)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func claimList(_ payload: [String: Any], now: Date) -> [JWTInfo.Claim] {
        let order = ["iss", "sub", "aud", "exp", "nbf", "iat", "jti"]
        let keys = order.filter { payload[$0] != nil } + payload.keys.filter { !order.contains($0) }.sorted()
        return keys.map { key in
            let raw = payload[key]!
            let text: String
            if let number = raw as? NSNumber, !(raw is Bool) { text = number.stringValue }
            else if let string = raw as? String { text = string }
            else { text = pretty(raw).replacingOccurrences(of: "\n", with: " ") }
            var note: String?
            if ["exp", "nbf", "iat"].contains(key), let number = raw as? NSNumber {
                let date = Date(timeIntervalSince1970: number.doubleValue)
                note = Timestamps.rows(for: Instant(date: date), timeZone: TimeZone(identifier: "UTC") ?? .current, now: now)
                    .first(where: { $0.label == "ISO 8601 (UTC)" })?.value
                let relative = Timestamps.relative(from: date, to: now)
                note = (note ?? "") + " · " + relative
                if key == "exp" { note = date < now ? "expired · " + (note ?? "") : "valid · " + (note ?? "") }
                if key == "nbf" { note = date > now ? "not yet valid · " + (note ?? "") : note }
            }
            return JWTInfo.Claim(name: key, value: text, note: note)
        }
    }

    /// Whether an HS256/HS384/HS512 signature matches `secret`. Nil for any other algorithm,
    /// which needs a key this tool does not take.
    static func verify(_ info: JWTInfo, secret: [UInt8]) -> Bool? {
        let algorithm: DigestAlgorithm
        switch info.algorithm {
        case "HS256": algorithm = .sha256
        case "HS384": algorithm = .sha384
        case "HS512": algorithm = .sha512
        default: return nil
        }
        guard let expected = algorithm.hmac(key: secret, message: info.signingInput) else { return nil }
        guard expected.count == info.signature.count else { return false }
        // A comparison that does not stop at the first difference.
        return zip(expected, info.signature).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - Byte order

enum ByteOrderTool {
    struct Reading: Equatable {
        let label: String
        let value: String
    }

    /// The bytes in the opposite order.
    static func swapped(_ bytes: [UInt8]) -> [UInt8] { bytes.reversed() }

    /// How the bytes read as a number, both ways round, at each width that fits
    /// (1, 2, 4 and 8 bytes) — and as a float at 4 and 8.
    static func readings(_ bytes: [UInt8]) -> [Reading] {
        var out: [Reading] = []
        func number(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
        guard [1, 2, 4, 8].contains(bytes.count) else { return out }
        let big = number(bytes)
        let little = number(bytes.reversed())
        let width = bytes.count * 8
        let bigPattern = BitPattern(width: width, value: big)
        let littlePattern = BitPattern(width: width, value: little)
        out.append(Reading(label: "Big-endian, unsigned", value: String(big)))
        out.append(Reading(label: "Big-endian, signed", value: String(bigPattern.signed)))
        out.append(Reading(label: "Little-endian, unsigned", value: String(little)))
        out.append(Reading(label: "Little-endian, signed", value: String(littlePattern.signed)))
        if bytes.count == 4 {
            out.append(Reading(label: "Big-endian float", value: FloatBits(format: .single, bits: big).storedText))
            out.append(Reading(label: "Little-endian float", value: FloatBits(format: .single, bits: little).storedText))
        } else if bytes.count == 8 {
            out.append(Reading(label: "Big-endian double", value: FloatBits(format: .double, bits: big).storedText))
            out.append(Reading(label: "Little-endian double", value: FloatBits(format: .double, bits: little).storedText))
        }
        return out
    }
}

// MARK: - Sizes

enum SizeUnits {
    struct Unit: Identifiable, Equatable {
        let name: String
        let symbol: String
        /// How many bits one unit is.
        let bits: Double
        var id: String { symbol }
    }

    static let units: [Unit] = [
        Unit(name: "bit", symbol: "bit", bits: 1),
        Unit(name: "byte", symbol: "B", bits: 8),
        Unit(name: "kilobyte", symbol: "KB", bits: 8e3),
        Unit(name: "megabyte", symbol: "MB", bits: 8e6),
        Unit(name: "gigabyte", symbol: "GB", bits: 8e9),
        Unit(name: "terabyte", symbol: "TB", bits: 8e12),
        Unit(name: "petabyte", symbol: "PB", bits: 8e15),
        Unit(name: "kibibyte", symbol: "KiB", bits: 8 * 1024),
        Unit(name: "mebibyte", symbol: "MiB", bits: 8 * 1_048_576),
        Unit(name: "gibibyte", symbol: "GiB", bits: 8 * 1_073_741_824),
        Unit(name: "tebibyte", symbol: "TiB", bits: 8 * 1_099_511_627_776),
        Unit(name: "pebibyte", symbol: "PiB", bits: 8 * 1_125_899_906_842_624),
    ]

    static func convert(_ value: Double, from unit: Unit) -> [(unit: Unit, text: String)] {
        let bits = value * unit.bits
        return units.map { ($0, format(bits / $0.bits)) }
    }

    /// Up to ten significant digits, no trailing zeros, scientific for the extremes.
    static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }
}
