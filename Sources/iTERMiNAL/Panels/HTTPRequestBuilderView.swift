import SwiftUI

/// Everything that makes up a request besides the method and URL, which
/// live in the pane's own toolbar: headers, and — for a method that takes
/// one — a body.
struct HTTPRequestBuilderView: View {
    @ObservedObject var model: HTTPClientModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headersSection(theme: theme)
                if !HTTPMethod.bodylessByConvention.contains(model.method) {
                    FadedDivider()
                    bodySection(theme: theme)
                }
            }
        }
        .background(theme.background)
    }

    private func headersSection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Headers")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            ForEach($model.headerFields) { $field in
                HStack(spacing: 6) {
                    TextField("Name", text: $field.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity)
                    Text(":")
                        .foregroundStyle(theme.textSecondary)
                    TextField("Value", text: $field.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity)
                    Button {
                        model.headerFields.removeAll { $0.id == field.id }
                        if model.headerFields.isEmpty {
                            model.headerFields.append(HTTPHeaderField(name: "", value: ""))
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }

            Button {
                model.headerFields.append(HTTPHeaderField(name: "", value: ""))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("Add Header")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func bodySection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Body")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            TextEditor(text: $model.bodyText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .frame(minHeight: 80)
        }
    }
}
