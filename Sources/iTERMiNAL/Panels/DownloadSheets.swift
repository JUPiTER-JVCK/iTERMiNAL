import SwiftUI
import AppKit

/// Shown before anything is fetched: what, from where, into which folder.
///
/// The files were named by a page, and the person never saw a request being
/// made when they pressed Download — so this is where they see the sites that
/// will be asked, and what will not be.
struct DownloadConfirmSheet: View {
    @ObservedObject var extraction: PageExtractionModel
    let pending: PendingDownload

    @EnvironmentObject private var settings: AppSettings

    /// The batch as it stands now: Change… may have replanned it since the sheet opened.
    private var current: PendingDownload { extraction.pendingDownload ?? pending }

    var body: some View {
        let plan = current.plan
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.items.isEmpty ? "Nothing to download" : "Download \(plan.items.count) file\(plan.items.count == 1 ? "" : "s")")
                .font(.headline)

            if !plan.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    labelled("From", plan.hosts.joined(separator: ", "))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Into")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text((current.destination.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(current.destination.path)
                        Button("Change…") { extraction.chooseDownloadFolder(settings: settings) }
                    }
                    labelled("Up to", "\(settings.httpMaxDownloadMB) MB each")
                }

                DisclosureGroup("The files (\(plan.items.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plan.items.prefix(200)) { item in
                                HStack(spacing: 6) {
                                    Text(item.fileName)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    Text(item.url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            if plan.items.count > 200 {
                                Text("… and \(plan.items.count - 200) more")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.system(size: 12))
            }

            if !plan.refused.isEmpty {
                DisclosureGroup("\(plan.refused.count) will not be fetched") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.refused.prefix(100), id: \.url) { refusal in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(refusal.url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(refusal.reason)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.system(size: 12))
            }

            if plan.overLimit > 0 {
                Text("\(plan.overLimit) more were left out: a batch is at most \(DownloadPlan.maxItems) files.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("Each file is requested without cookies or credentials. Nothing is overwritten, and each file is marked as downloaded from the web.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { extraction.pendingDownload = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { extraction.confirmDownload(settings: settings) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.items.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
        .tint(settings.accentColor)
    }

    private func labelled(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }
}

/// What is being saved, file by file, and what became of each.
struct DownloadProgressSheet: View {
    @ObservedObject var downloader: AssetDownloader
    @ObservedObject var extraction: PageExtractionModel

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let summary = downloader.summary
        VStack(alignment: .leading, spacing: 10) {
            Text(downloader.isRunning ? "Downloading…" : "Finished")
                .font(.headline)
            if let folder = downloader.folder {
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.path)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(downloader.entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.item.fileName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            status(entry.state)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))

            Text(summaryLine(summary))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                if downloader.isRunning {
                    Button("Stop") { downloader.cancel() }
                }
                Spacer()
                if !downloader.savedURLs.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(downloader.savedURLs)
                    }
                }
                Button("Done") {
                    extraction.showingDownloadProgress = false
                    downloader.reset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloader.isRunning)
            }
        }
        .padding(16)
        .frame(width: 520)
        .tint(settings.accentColor)
    }

    @ViewBuilder
    private func status(_ state: AssetDownloader.Entry.State) -> some View {
        switch state {
        case .waiting:
            Text("waiting").font(.system(size: 11)).foregroundStyle(.secondary)
        case .receiving(let received, let expected):
            if let expected {
                ProgressView(value: Double(received), total: Double(expected))
                    .frame(width: 90)
            } else {
                Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .saved(_, let bytes):
            Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(reason)
        case .cancelled:
            Text("stopped").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func summaryLine(_ summary: (saved: Int, failed: Int, cancelled: Int, bytes: Int64)) -> String {
        var parts = ["\(summary.saved) saved"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.cancelled > 0 { parts.append("\(summary.cancelled) stopped") }
        parts.append(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
