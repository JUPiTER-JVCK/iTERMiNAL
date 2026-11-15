import SwiftUI

/// The selected bytes read as what they might be: numbers of each size, a
/// character, text, a time, an address. The readings are `ByteInterpreter`'s.
///
/// Reading a file is guessing, and seeing the guesses side by side is how a
/// format gets learned: `00 00 80 3F` is 1.0 as a little-endian float and not as
/// anything else, and this is where that shows.
struct ByteInspectorView: View {
    let bytes: [UInt8]
    let selectedCount: Int64
    @Binding var endianness: Endianness
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            readings
        }
        .background(theme.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(selectedCount == 0
                 ? "Nothing selected"
                 : "\(selectedCount) \(selectedCount == 1 ? "byte" : "bytes") selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            Picker("Byte order", selection: $endianness) {
                ForEach(Endianness.allCases, id: \.self) { order in
                    Text(order == .little ? "Little-endian" : "Big-endian").tag(order)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Which end of a number comes first: little-endian, as on x86 and Apple silicon, or big-endian, as on a network")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var readings: some View {
        let rows = ByteInterpreter.interpret(bytes, endianness: endianness)
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if rows.isEmpty {
                    Text("Select a byte to read it as a number, a character or text.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 84, alignment: .leading)
                        Text(row.value)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
