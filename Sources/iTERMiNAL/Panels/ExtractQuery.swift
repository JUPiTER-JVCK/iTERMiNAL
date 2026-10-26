import SwiftUI

/// The query box: ask the response a question in the language a scraper knows —
/// CSS selectors, XPath, JSONPath or a regular expression — and get the answers
/// as a list that can be copied, saved, opened and downloaded like any other.
struct ExtractQuery: View {
    @ObservedObject var extraction: PageExtractionModel
    let theme: Theme

    @EnvironmentObject private var settings: AppSettings
    @FocusState private var focused: Bool

    private var languages: [QueryLanguage] { extraction.extraction?.languages ?? [] }

    /// A few to start from. Not addresses and not guesses at what a site has:
    /// questions about the markup in front of you.
    private func examples(for language: QueryLanguage) -> [(label: String, query: String)] {
        switch language {
        case .css:
            return [
                ("Every link's address", "a::attr(href)"),
                ("Headlines", "h1, h2, h3"),
                ("Image addresses", "img::attr(src)"),
                ("Open Graph tags", "meta[property^=og:]::attr(content)"),
                ("The first paragraph", "p:first-of-type::text"),
                ("Links that say \"download\"", "a:contains(\"Download\")::attr(href)"),
            ]
        case .xpath:
            return [
                ("Every link's address", "//a/@href"),
                ("Headlines", "//h2/text()"),
                ("Links inside the main content", "//main//a/@href"),
                ("Images with alt text", "//img[@alt]/@src"),
                ("Table cells", "//table//td/text()"),
            ]
        case .jsonPath:
            return [
                ("Everything", "$..*"),
                ("Every url field", "$..url"),
                ("The first item", "$[0]"),
                ("Names of all items", "$..name"),
            ]
        case .regex:
            return [
                ("Web addresses", "https?://[^\\s\"'<>]+"),
                ("Dates (2024-06-01)", "(\\d{4})-(\\d{2})-(\\d{2})"),
                ("Prices", "[$€£]\\s?\\d+(?:[.,]\\d{2})?"),
                ("Hashtags", "#\\w+"),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            FadedDivider()
            results
        }
        .onAppear { focused = true }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Language", selection: $extraction.queryLanguage) {
                    ForEach(languages) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Menu("Examples") {
                    ForEach(examples(for: extraction.queryLanguage), id: \.query) { example in
                        Button(example.label) {
                            extraction.queryText = example.query
                            extraction.runQuery()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                TextField("", text: $extraction.queryText, prompt: Text(extraction.queryLanguage.placeholder))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { extraction.runQuery() }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.surface))
                if extraction.isQuerying {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") { extraction.runQuery() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(settings.accentColor.opacity(0.22)))
                        .disabled(extraction.queryText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            switch extraction.queryLanguage {
            case .css, .xpath:
                HStack(spacing: 8) {
                    Text("Take")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    Picker("Take", selection: $extraction.queryOutput) {
                        ForEach(PageExtractionModel.OutputChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if extraction.queryOutput == .attribute {
                        TextField("attribute", text: $extraction.queryAttribute)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 100)
                    }
                    Spacer(minLength: 0)
                }
            case .regex:
                Toggle("Ignore case", isOn: $extraction.queryIgnoreCase)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            case .jsonPath:
                EmptyView()
            }

            Text(extraction.queryLanguage.summary)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if let error = extraction.queryError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        } else if let outcome = extraction.queryResult {
            if let note = outcome.note, outcome.table.rows.isEmpty || outcome.table.truncated {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !outcome.table.rows.isEmpty {
                ExtractResults(extraction: extraction, table: outcome.table, section: .query, theme: theme)
            } else {
                Spacer(minLength: 0)
            }
        } else {
            Text("Type a query and press Return. What it finds is listed here.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}
