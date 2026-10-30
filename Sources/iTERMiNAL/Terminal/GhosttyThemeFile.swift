import Foundation

/// A colour theme read from a Ghostty theme file: plain `key = value` lines,
///
///     palette = 0=#45475a
///     background = #1e1e2e
///     foreground = #cdd6f4
///
/// Foundation only, so the parsing is checked off a Mac. Only colour data is
/// taken. Everything else a Ghostty file can hold — fonts, keybinds, commands
/// to run — is ignored without being read as anything, so importing a theme
/// can never change what the app does, only how it looks.
struct GhosttyThemeFile: Equatable {
    var background: UInt32
    var foreground: UInt32
    /// The sixteen ANSI colours, normal then bright.
    var ansi: [UInt32]

    /// Dark when the background is darker than middle grey, by relative
    /// luminance. The same call a person makes looking at it.
    var isDark: Bool {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((background >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return luminance < 0.4
    }

    enum Problem: Error, Equatable {
        case tooLarge
        case missing(String)
        case badColor(String)

        var message: String {
            switch self {
            case .tooLarge:
                return "That file is too large to be a theme."
            case .missing(let what):
                return "The file has no \(what), so it isn't a complete theme."
            case .badColor(let line):
                return "“\(line)” isn't a colour written as #rrggbb."
            }
        }
    }

    static let maxBytes = 64 * 1024

    static func parse(_ text: String) -> Result<GhosttyThemeFile, Problem> {
        guard text.utf8.count <= maxBytes else { return .failure(.tooLarge) }

        var background: UInt32?
        var foreground: UInt32?
        var palette: [Int: UInt32] = [:]

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "background":
                guard let color = hex(value) else { return .failure(.badColor(line)) }
                background = color
            case "foreground":
                guard let color = hex(value) else { return .failure(.badColor(line)) }
                foreground = color
            case "palette":
                // `N=#rrggbb`
                guard let inner = value.firstIndex(of: "=") else { continue }
                let number = value[..<inner].trimmingCharacters(in: .whitespaces)
                let spelled = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
                // Entries past 15 are the 256-colour cube, which the app does not
                // theme: the terminal computes them.
                guard let index = Int(number), (0...255).contains(index) else { continue }
                guard index <= 15 else { continue }
                guard let color = hex(spelled) else { return .failure(.badColor(line)) }
                palette[index] = color
            default:
                continue
            }
        }

        guard let background else { return .failure(.missing("background colour")) }
        guard let foreground else { return .failure(.missing("foreground colour")) }
        var ansi: [UInt32] = []
        for index in 0..<16 {
            guard let color = palette[index] else {
                return .failure(.missing("palette entry \(index)"))
            }
            ansi.append(color)
        }
        return .success(GhosttyThemeFile(background: background, foreground: foreground, ansi: ansi))
    }

    /// `#rrggbb` or `rrggbb`. Not the three-digit or named forms.
    static func hex(_ text: String) -> UInt32? {
        var digits = text
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        return value
    }
}
