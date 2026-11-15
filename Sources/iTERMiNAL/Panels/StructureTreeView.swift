import SwiftUI

/// The Structure outlook's tree: the fields a file's format says it is made of, each tied
/// to its bytes. Click a field and its bytes are selected in the dump below; select bytes
/// in the dump and the field that holds them is shown here.
///
/// The lines are `StructureOutline`'s, worked out and checked away from the view; what is
/// here is drawing them, and passing clicks on to the model. It is a list of lines in a
/// lazy stack, so a capture of a hundred thousand packets costs the lines on screen.
struct StructureTreeView: View {
    @ObservedObject var model: BytesViewerModel
    let theme: Theme
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            FadedDivider()
            content
            if let node = model.focusedNode {
                FadedDivider()
                detail(of: node)
            }
        }
        .background(theme.background)
    }

    // MARK: Header

    @ViewBuilder
    private var summaryBar: some View {
        switch model.structure {
        case .idle:
            EmptyView()
        case .parsing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the structure…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        case .ready(let result):
            VStack(alignment: .leading, spacing: 2) {
                if let summary = result.outcome.summary ?? result.identity.map({ $0.name }) {
                    Text(summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                }
                if let limit = result.outcome.listingLimit {
                    Text(limit)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                if let problem = result.outcome.problems.first {
                    let more = result.outcome.problems.count - 1
                    Text(more > 0 ? "\(problem) (and \(more) more)" : problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.surface)
        }
    }

    // MARK: Lines

    @ViewBuilder
    private var content: some View {
        switch model.structure {
        case .idle, .parsing:
            Spacer(minLength: 0)
        case .ready(let result):
            if result.outcome.roots.isEmpty {
                Text(result.message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tree
            }
        }
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.structureRows) { row in
                        line(row)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: model.structureScroll) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.nodeID)
            }
        }
    }

    @ViewBuilder
    private func line(_ row: StructureRow) -> some View {
        switch row.content {
        case .node(let node):
            nodeLine(row, node)
        case .more(let parentID, let remaining):
            moreLine(row, parentID: parentID, remaining: remaining)
        }
    }

    private func nodeLine(_ row: StructureRow, _ node: FieldNode) -> some View {
        let isFocused = model.focusedNode?.id == node.id
        return HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * 14 + 4, height: 1)
            if node.isExpandable {
                Button {
                    model.toggleExpansion(of: node)
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .accessibilityLabel(row.isExpanded ? "Collapse \(node.name)" : "Expand \(node.name)")
            } else {
                Color.clear.frame(width: 14, height: 20)
            }
            Button {
                model.selectNode(node)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(kindColor(node.kind))
                        .frame(width: 7, height: 7)
                    Text(node.name)
                        .font(.system(size: 12, weight: node.kind == .container ? .medium : .regular))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let value = node.value {
                        Text(value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(rangeSummary(node))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.vertical, 2)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isFocused ? accent.opacity(0.22) : Color.clear)
    }

    private func moreLine(_ row: StructureRow, parentID: String, remaining: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * 14 + 18, height: 1)
            Button {
                model.showMore(under: parentID)
            } label: {
                Text("Show \(min(remaining, StructureOutline.page)) more · \(remaining) not listed")
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    // MARK: Detail

    /// What the selected field is, in words: where it is, what it says, and why.
    private func detail(of node: FieldNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(node.name) · \(rangeText(node))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if let value = node.value {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if let note = node.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface)
    }

    // MARK: Words and colours

    private func hex(_ value: Int64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    /// "0x10 · 4 B", for the end of a line.
    private func rangeSummary(_ node: FieldNode) -> String {
        "\(hex(node.offset)) · \(node.length) B"
    }

    private func rangeText(_ node: FieldNode) -> String {
        switch node.length {
        case 0: return "no bytes, at \(hex(node.offset))"
        case 1: return "byte \(hex(node.offset))"
        default: return "bytes \(hex(node.offset))–\(hex(node.lastByte)) (\(node.length))"
        }
    }

    private func kindColor(_ kind: FieldNode.Kind) -> Color {
        switch kind {
        case .container: return theme.textSecondary
        case .integer: return Color(hex: 0x4F8EF7)
        case .text: return Color(hex: 0x3FB950)
        case .bytes: return Color(hex: 0xD29922)
        case .flags: return Color(hex: 0xA371F7)
        case .magic: return Color(hex: 0xDB61A2)
        case .checksum: return Color(hex: 0x2DBFB8)
        case .address: return Color(hex: 0x58A6FF)
        case .time: return Color(hex: 0x56D364)
        case .padding: return theme.textSecondary.opacity(0.5)
        case .problem: return Color.red
        }
    }
}
