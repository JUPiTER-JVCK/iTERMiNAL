import Foundation

/// Turns the character references in markup — `&amp;`, `&#39;`, `&#x1F600;`,
/// `&eacute;` — back into the characters they stand for.
///
/// The table is HTML 4's named set (the 252 a real page uses) plus `&apos;`.
/// That is deliberately not all 2,231 of HTML5's: the rest are mathematical
/// and typographic oddities that show up in no page this app is pointed at,
/// and an unknown name is left as written rather than guessed at.
enum HTMLEntities {
    /// Named references to their code points.
    static let named: [String: UInt32] = [
        "AElig": 0xC6, "Aacute": 0xC1, "Acirc": 0xC2, "Agrave": 0xC0, "Alpha": 0x391, "Aring": 0xC5,
        "Atilde": 0xC3, "Auml": 0xC4, "Beta": 0x392, "Ccedil": 0xC7, "Chi": 0x3A7, "Dagger": 0x2021,
        "Delta": 0x394, "ETH": 0xD0, "Eacute": 0xC9, "Ecirc": 0xCA, "Egrave": 0xC8, "Epsilon": 0x395,
        "Eta": 0x397, "Euml": 0xCB, "Gamma": 0x393, "Iacute": 0xCD, "Icirc": 0xCE, "Igrave": 0xCC,
        "Iota": 0x399, "Iuml": 0xCF, "Kappa": 0x39A, "Lambda": 0x39B, "Mu": 0x39C, "Ntilde": 0xD1,
        "Nu": 0x39D, "OElig": 0x152, "Oacute": 0xD3, "Ocirc": 0xD4, "Ograve": 0xD2, "Omega": 0x3A9,
        "Omicron": 0x39F, "Oslash": 0xD8, "Otilde": 0xD5, "Ouml": 0xD6, "Phi": 0x3A6, "Pi": 0x3A0,
        "Prime": 0x2033, "Psi": 0x3A8, "Rho": 0x3A1, "Scaron": 0x160, "Sigma": 0x3A3, "THORN": 0xDE,
        "Tau": 0x3A4, "Theta": 0x398, "Uacute": 0xDA, "Ucirc": 0xDB, "Ugrave": 0xD9, "Upsilon": 0x3A5,
        "Uuml": 0xDC, "Xi": 0x39E, "Yacute": 0xDD, "Yuml": 0x178, "Zeta": 0x396, "aacute": 0xE1,
        "acirc": 0xE2, "acute": 0xB4, "aelig": 0xE6, "agrave": 0xE0, "alefsym": 0x2135, "alpha": 0x3B1,
        "amp": 0x26, "and": 0x2227, "ang": 0x2220, "aring": 0xE5, "asymp": 0x2248, "atilde": 0xE3,
        "auml": 0xE4, "bdquo": 0x201E, "beta": 0x3B2, "brvbar": 0xA6, "bull": 0x2022, "cap": 0x2229,
        "ccedil": 0xE7, "cedil": 0xB8, "cent": 0xA2, "chi": 0x3C7, "circ": 0x2C6, "clubs": 0x2663,
        "cong": 0x2245, "copy": 0xA9, "crarr": 0x21B5, "cup": 0x222A, "curren": 0xA4, "dArr": 0x21D3,
        "dagger": 0x2020, "darr": 0x2193, "deg": 0xB0, "delta": 0x3B4, "diams": 0x2666, "divide": 0xF7,
        "eacute": 0xE9, "ecirc": 0xEA, "egrave": 0xE8, "empty": 0x2205, "emsp": 0x2003, "ensp": 0x2002,
        "epsilon": 0x3B5, "equiv": 0x2261, "eta": 0x3B7, "eth": 0xF0, "euml": 0xEB, "euro": 0x20AC,
        "exist": 0x2203, "fnof": 0x192, "forall": 0x2200, "frac12": 0xBD, "frac14": 0xBC, "frac34": 0xBE,
        "frasl": 0x2044, "gamma": 0x3B3, "ge": 0x2265, "gt": 0x3E, "hArr": 0x21D4, "harr": 0x2194,
        "hearts": 0x2665, "hellip": 0x2026, "iacute": 0xED, "icirc": 0xEE, "iexcl": 0xA1, "igrave": 0xEC,
        "image": 0x2111, "infin": 0x221E, "int": 0x222B, "iota": 0x3B9, "iquest": 0xBF, "isin": 0x2208,
        "iuml": 0xEF, "kappa": 0x3BA, "lArr": 0x21D0, "lambda": 0x3BB, "lang": 0x2329, "laquo": 0xAB,
        "larr": 0x2190, "lceil": 0x2308, "ldquo": 0x201C, "le": 0x2264, "lfloor": 0x230A, "lowast": 0x2217,
        "loz": 0x25CA, "lrm": 0x200E, "lsaquo": 0x2039, "lsquo": 0x2018, "lt": 0x3C, "macr": 0xAF,
        "mdash": 0x2014, "micro": 0xB5, "middot": 0xB7, "minus": 0x2212, "mu": 0x3BC, "nabla": 0x2207,
        "nbsp": 0xA0, "ndash": 0x2013, "ne": 0x2260, "ni": 0x220B, "not": 0xAC, "notin": 0x2209,
        "nsub": 0x2284, "ntilde": 0xF1, "nu": 0x3BD, "oacute": 0xF3, "ocirc": 0xF4, "oelig": 0x153,
        "ograve": 0xF2, "oline": 0x203E, "omega": 0x3C9, "omicron": 0x3BF, "oplus": 0x2295, "or": 0x2228,
        "ordf": 0xAA, "ordm": 0xBA, "oslash": 0xF8, "otilde": 0xF5, "otimes": 0x2297, "ouml": 0xF6,
        "para": 0xB6, "part": 0x2202, "permil": 0x2030, "perp": 0x22A5, "phi": 0x3C6, "pi": 0x3C0,
        "piv": 0x3D6, "plusmn": 0xB1, "pound": 0xA3, "prime": 0x2032, "prod": 0x220F, "prop": 0x221D,
        "psi": 0x3C8, "quot": 0x22, "rArr": 0x21D2, "radic": 0x221A, "rang": 0x232A, "raquo": 0xBB,
        "rarr": 0x2192, "rceil": 0x2309, "rdquo": 0x201D, "real": 0x211C, "reg": 0xAE, "rfloor": 0x230B,
        "rho": 0x3C1, "rlm": 0x200F, "rsaquo": 0x203A, "rsquo": 0x2019, "sbquo": 0x201A, "scaron": 0x161,
        "sdot": 0x22C5, "sect": 0xA7, "shy": 0xAD, "sigma": 0x3C3, "sigmaf": 0x3C2, "sim": 0x223C,
        "spades": 0x2660, "sub": 0x2282, "sube": 0x2286, "sum": 0x2211, "sup": 0x2283, "sup1": 0xB9,
        "sup2": 0xB2, "sup3": 0xB3, "supe": 0x2287, "szlig": 0xDF, "tau": 0x3C4, "there4": 0x2234,
        "theta": 0x3B8, "thetasym": 0x3D1, "thinsp": 0x2009, "thorn": 0xFE, "tilde": 0x2DC, "times": 0xD7,
        "trade": 0x2122, "uArr": 0x21D1, "uacute": 0xFA, "uarr": 0x2191, "ucirc": 0xFB, "ugrave": 0xF9,
        "uml": 0xA8, "upsih": 0x3D2, "upsilon": 0x3C5, "uuml": 0xFC, "weierp": 0x2118, "xi": 0x3BE,
        "yacute": 0xFD, "yen": 0xA5, "yuml": 0xFF, "zeta": 0x3B6, "zwj": 0x200D, "zwnj": 0x200C,
        "apos": 0x27,
    ]

    /// Names HTML5 lets stand without the closing `;` in running text:
    /// `&copy 2024`. Nowhere else — see `decode`'s `inAttribute`.
    private static let legacyWithoutSemicolon: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    /// What the numeric references 128–159 mean to a browser, which reads them
    /// as Windows-1252 rather than as the control characters Unicode puts
    /// there. `&#150;` is an en dash on every page that ever wrote it.
    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020,
        0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152,
        0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
        0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
        0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    /// `text` with its references replaced.
    ///
    /// `inAttribute` is stricter, the way browsers are: a name with no `;` is
    /// left alone, so `?a=1&copy=2` stays a query string instead of becoming
    /// `?a=1©=2`.
    static func decode(_ text: String, inAttribute: Bool = false) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        return String(decoding: decode(Array(text.utf8)[...], inAttribute: inAttribute), as: UTF8.self)
    }

    /// The same on UTF-8 bytes, which is what the parser has in hand.
    static func decode(_ bytes: ArraySlice<UInt8>, inAttribute: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            let byte = bytes[i]
            guard byte == UInt8(ascii: "&"), i + 1 < end else {
                out.append(byte)
                i += 1
                continue
            }
            if let (scalar, next) = reference(in: bytes, at: i, inAttribute: inAttribute) {
                out.append(contentsOf: Array(String(scalar).utf8))
                i = next
            } else {
                out.append(byte)
                i += 1
            }
        }
        return out
    }

    /// One reference starting at `start` (a `&`), and the index just past it.
    private static func reference(
        in bytes: ArraySlice<UInt8>, at start: Int, inAttribute: Bool
    ) -> (Unicode.Scalar, Int)? {
        let end = bytes.endIndex
        var j = start + 1
        if bytes[j] == UInt8(ascii: "#") {
            j += 1
            var radix: UInt32 = 10
            if j < end, bytes[j] == UInt8(ascii: "x") || bytes[j] == UInt8(ascii: "X") {
                radix = 16
                j += 1
            }
            var value: UInt32 = 0
            var digits = 0
            while j < end, let digit = digitValue(bytes[j]), digit < radix, digits < 8 {
                value = value &* radix &+ digit
                digits += 1
                j += 1
            }
            guard digits > 0 else { return nil }
            if j < end, bytes[j] == UInt8(ascii: ";") { j += 1 }
            if let mapped = windows1252[value] { value = mapped }
            // Nothing, a surrogate, or past Unicode: the replacement character.
            let scalar = Unicode.Scalar(value).flatMap { value == 0 ? nil : $0 } ?? "\u{FFFD}"
            return (scalar, j)
        }
        // A name: letters and digits, at most 31 of them.
        let nameStart = j
        while j < end, j - nameStart < 31, isNameByte(bytes[j]) { j += 1 }
        guard j > nameStart else { return nil }
        let name = String(decoding: bytes[nameStart..<j], as: UTF8.self)
        let hasSemicolon = j < end && bytes[j] == UInt8(ascii: ";")
        guard let code = named[name], let scalar = Unicode.Scalar(code) else { return nil }
        if hasSemicolon { return (scalar, j + 1) }
        if !inAttribute, legacyWithoutSemicolon.contains(name) { return (scalar, j) }
        return nil
    }

    private static func digitValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}
