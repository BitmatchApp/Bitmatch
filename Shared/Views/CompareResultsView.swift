import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// Shared comparison outcome on every platform: names each differing path so a
/// reported difference can be investigated, and exports the complete record.
/// Paths are selectable for copying into issue reports.
struct CompareResultsView: View {
    let stats: CompareStats
    let leftName: String
    let rightName: String
    let verificationMode: VerificationMode
    @State private var exportDocument: CompareReportDocument?
    @State private var showExport = false
    @State private var exportType = UTType.json
    @State private var errorMessage: String?

    private static let maxListedPaths = 200

    /// Headline wording and tone come from the shared model, so Quick mode
    /// can only ever say "Sizes match, not verified" (amber), never green.
    private var verdict: CompareVerdictPresentation {
        let outcome = CompareOutcome.resolve(stats: stats, end: .completed, mode: verificationMode) ?? .differ
        return CompareVerdictPresentation.make(
            outcome,
            leftName: leftName,
            rightName: rightName,
            mode: verificationMode,
            stats: stats
        )
    }

    private var verifiesContents: Bool {
        CompareCheckPlan.make(for: verificationMode).verifiesContents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompareVerdictHeader(verdict: verdict)
            Text("\(stats.commonCount) \(verifiesContents ? "matching" : "same size") · \(verificationMode.rawValue) mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !stats.isClean {
                pathSection(
                    title: "Missing from \(rightName)",
                    systemImage: "minus.circle",
                    paths: stats.onlyInLeftPaths
                )
                pathSection(
                    title: "Extra in \(rightName)",
                    systemImage: "plus.circle",
                    paths: stats.onlyInRightPaths
                )
                pathSection(
                    title: verifiesContents ? "Content differs" : "Size differs",
                    systemImage: "exclamationmark.triangle",
                    paths: stats.mismatchedPaths
                )
                Text("Expand a list to see the files. Extra files do not mean the matching copies are damaged. Missing files or mismatches need attention before clearing the source. Export differences includes file paths; diagnostics does not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Menu("Export differences") {
                    Button("JSON report") { export(asCSV: false) }
                    Button("CSV paths") { export(asCSV: true) }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(stats.isClean)
                Spacer()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .fileExporter(
            isPresented: $showExport,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "BitMatch-compare"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private func pathSection(title: String, systemImage: String, paths: [String]) -> some View {
        Group {
            if !paths.isEmpty {
                DisclosureGroup {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(paths.prefix(Self.maxListedPaths), id: \.self) { path in
                            Text(path)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if paths.count > Self.maxListedPaths {
                            Text("…and \(paths.count - Self.maxListedPaths) more. Export includes every path.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Label("\(title) (\(paths.count))", systemImage: systemImage)
                        .font(.subheadline)
                }
            }
        }
    }

    private func export(asCSV: Bool) {
        do {
            exportDocument = try CompareReportDocument(
                stats: stats,
                leftName: leftName,
                rightName: rightName,
                verificationMode: verificationMode,
                asCSV: asCSV
            )
            exportType = asCSV ? .commaSeparatedText : .json
            showExport = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CompareReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    let data: Data
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }

    init(
        stats: CompareStats,
        leftName: String,
        rightName: String,
        verificationMode: VerificationMode,
        exportedAt: Date = Date(),
        asCSV: Bool
    ) throws {
        if asCSV {
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            let header = "category,path\n"
            var rows: [String] = []
            rows += stats.onlyInLeftPaths.map { ["only-in-source", $0].map(quote).joined(separator: ",") }
            rows += stats.onlyInRightPaths.map { ["only-in-destination", $0].map(quote).joined(separator: ",") }
            let mismatchCategory = verificationMode == .quick ? "size-differs" : "content-differs"
            rows += stats.mismatchedPaths.map { [mismatchCategory, $0].map(quote).joined(separator: ",") }
            data = Data((header + rows.joined(separator: "\n") + "\n").utf8)
        } else {
            struct Report: Encodable {
                let left: String
                let right: String
                let verificationMode: String
                let exportedAt: Date
                let clean: Bool
                let commonCount: Int
                let onlyInSourceCount: Int
                let onlyInDestinationCount: Int
                let mismatchedCount: Int
                let onlyInSource: [String]
                let onlyInDestination: [String]
                let mismatched: [String]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(Report(
                left: leftName,
                right: rightName,
                verificationMode: verificationMode.rawValue,
                exportedAt: exportedAt,
                clean: stats.isClean,
                commonCount: stats.commonCount,
                onlyInSourceCount: stats.onlyInLeftCount,
                onlyInDestinationCount: stats.onlyInRightCount,
                mismatchedCount: stats.mismatchedCount,
                onlyInSource: stats.onlyInLeftPaths,
                onlyInDestination: stats.onlyInRightPaths,
                mismatched: stats.mismatchedPaths
            ))
        }
    }
}
