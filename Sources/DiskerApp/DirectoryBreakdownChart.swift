import Charts
import DiskerCore
import SwiftUI

/// An interactive, non-additive comparison of complete immediate child folders.
/// Nested summaries are excluded by DiskerCore.DirectoryBreakdown.
struct SWDirectoryBreakdownChart: View {
    let folder: FolderObservation

    @State private var sizeBasis: DirectoryBreakdown.SizeBasis = .allocated
    @State private var selectedDirectoryPath: String?

    private var directories: [DirectoryUsage] {
        DirectoryBreakdown.ranked(folder.subdirectorySummaries, by: sizeBasis)
    }

    private var selectedDirectory: DirectoryUsage? {
        directories.first { $0.rootRelativePath == selectedDirectoryPath } ?? directories.first
    }

    private var maximumValue: Double {
        Double(directories.map { sizeBasis.bytes(in: $0) }.max() ?? 1)
    }

    var body: some View {
        if !folder.byteAccountingOverflowed, directories.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Immediate subfolder sizes")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        sizeBasisPicker
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Immediate subfolder sizes")
                            .font(.subheadline.weight(.semibold))
                        sizeBasisPicker
                    }
                }

                Text("Shows up to eight immediate children ranked by the selected measure. Nested folder totals are excluded, and files directly inside the selected root are not shown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !folder.complete {
                    Label("Only completely measured subfolders are ranked; other content remains unknown.", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if folder.subdirectorySummariesTruncated {
                    Text("The scanner retained a bounded directory list; some subfolders may be omitted from this ranking.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Chart(directories, id: \.rootRelativePath) { directory in
                    BarMark(
                        x: .value("Size in bytes", Double(sizeBasis.bytes(in: directory))),
                        y: .value("Subfolder", directory.rootRelativePath)
                    )
                    .foregroundStyle(
                        (selectedDirectory?.rootRelativePath == directory.rootRelativePath)
                            ? Color.accentColor : Color.accentColor.opacity(0.58)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .chartYSelection(value: $selectedDirectoryPath)
                .chartYScale(domain: directories.map(\.rootRelativePath))
                .chartXScale(domain: 0...max(1, maximumValue * 1.25))
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let path = value.as(String.self) {
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        if let bytes = value.as(Double.self), bytes <= maximumValue {
                            AxisValueLabel {
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Self.clampedInt64(bytes), countStyle: .file
                                ))
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in plot.clipped() }
                .frame(height: CGFloat(directories.count * 27 + 12))
                .animation(.snappy(duration: 0.22), value: sizeBasis)
                .accessibilityLabel("Interactive comparison of immediate subfolder sizes")
                .accessibilityHint("Select a bar to review its exact path and both size measurements.")

                if let selectedDirectory {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedDirectory.rootRelativePath)
                                .font(.caption.weight(.semibold))
                                .textSelection(.enabled)
                            Text("\(format(selectedDirectory.logicalBytes)) logical · ~\(format(selectedDirectory.allocatedBytes)) allocated · \(fileCountText(selectedDirectory.fileCount))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: folder.path)
                                    .appendingPathComponent(selectedDirectory.rootRelativePath, isDirectory: true)
                            ])
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal subfolder in Finder")
                        .accessibilityLabel("Reveal \(selectedDirectory.rootRelativePath) in Finder")
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var sizeBasisPicker: some View {
        Picker("Size basis", selection: $sizeBasis) {
            Text("Logical").tag(DirectoryBreakdown.SizeBasis.logical)
            Text("Allocated estimate").tag(DirectoryBreakdown.SizeBasis.allocated)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Choose the subfolder chart size basis")
    }

    private func fileCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("%#@fileCount@", comment: "A localized file count"), Int64(count)
        )
    }

    private static func clampedInt64(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(Int64.max) else { return Int64.max }
        return Int64(value)
    }
}
