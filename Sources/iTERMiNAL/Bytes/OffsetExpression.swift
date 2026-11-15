import Foundation

/// What can be typed into "Go to offset". Foundation only, so what each form
/// means, and what happens when it is nonsense or runs off the file, is checked.
///
///     0x1F40   $1F40   1F40h     hexadecimal
///     8000                       decimal
///     +0x10    -16               from the cursor
///     end      end-0x20          from the last byte
///     50%                        part of the way through
///
/// A number with nothing to say it is hex is decimal: the offset column prints
/// hex without a prefix, and "00000100" read as decimal would be a quiet mistake
/// the other way round.
enum OffsetExpression {
    enum Failure: Error, Equatable {
        case empty
        case notANumber
        /// Not a byte of the file; its length.
        case outOfRange(length: Int64)
    }

    /// The offset `text` names, in a file of `length` bytes with the cursor at `cursor`.
    static func resolve(_ text: String, cursor: Int64, length: Int64) -> Result<Int64, Failure> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return .failure(.empty) }
        let outOfRange = Result<Int64, Failure>.failure(.outOfRange(length: length))

        let target: Int64
        if typed == "end" {
            target = length - 1
        } else if typed.hasPrefix("end") {
            let rest = typed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("-"),
                  let back = number(String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)) else {
                return .failure(.notANumber)
            }
            let (value, overflow) = (length - 1).subtractingReportingOverflow(back)
            if overflow { return outOfRange }
            target = value
        } else if typed.hasSuffix("%") {
            guard let percent = number(String(typed.dropLast()).trimmingCharacters(in: .whitespaces)),
                  percent <= 100 else { return .failure(.notANumber) }
            // Whole bytes, rounded down; 100% is the last byte, not one past it.
            target = percent == 100 ? length - 1 : (length / 100) * percent + (length % 100) * percent / 100
        } else if typed.hasPrefix("+") || typed.hasPrefix("-") {
            guard let step = number(String(typed.dropFirst()).trimmingCharacters(in: .whitespaces)) else {
                return .failure(.notANumber)
            }
            let (value, overflow) = typed.hasPrefix("+")
                ? cursor.addingReportingOverflow(step)
                : cursor.subtractingReportingOverflow(step)
            if overflow { return outOfRange }
            target = value
        } else {
            guard let value = number(typed) else { return .failure(.notANumber) }
            target = value
        }

        guard target >= 0, target < length else { return outOfRange }
        return .success(target)
    }

    /// The sentence for a failure.
    static func message(_ failure: Failure) -> String {
        switch failure {
        case .empty:
            return "Type an offset: 0x1F40, 8000, +16, end-0x20 or 50%."
        case .notANumber:
            return "Not an offset. Try 0x1F40 (hex), 8000 (decimal), +16, end-0x20 or 50%."
        case .outOfRange(let length):
            return "That is not in the file, which is \(length) bytes."
        }
    }

    /// A non-negative number, in hex if it says so, else in decimal; nil if it is
    /// neither. One too big for 64 bits is `Int64.max`, which is never a byte of
    /// a file, so it falls out as out of range rather than as nonsense.
    private static func number(_ text: String) -> Int64? {
        var digits = Substring(text)
        var radix = 10
        if digits.hasPrefix("0x") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.hasPrefix("$") {
            digits = digits.dropFirst()
            radix = 16
        } else if digits.hasSuffix("h") {
            digits = digits.dropLast()
            radix = 16
        }
        guard !digits.isEmpty else { return nil }
        // Checked by hand: `Int64("+5")` and `Int64("-5")` parse, and neither is a bare number.
        let allowed: (Character) -> Bool = radix == 16
            ? { $0.isASCII && $0.isHexDigit }
            : { $0.isASCII && $0.isNumber }
        guard digits.allSatisfy(allowed) else { return nil }
        return Int64(digits, radix: radix) ?? Int64.max
    }
}
