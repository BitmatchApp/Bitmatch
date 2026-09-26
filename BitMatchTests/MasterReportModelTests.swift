import Foundation
import Testing
@testable import BitMatch

/// The one Master Report screen's model and rules (UI plan step 4.10).
/// Scanning and rendering are injected, so these run without a drive or a PDF.
@MainActor
struct MasterReportModelTests {

    // MARK: - Fixtures

    private func card(camera: String, roll: String, verified: Bool = true,
                      files: Int = 10, bytes: Int64 = 1_000, finished: Date = Date()) -> TransferCard {
        let source = URL(fileURLWithPath: "/Volumes/\(roll)")
        let folder = FolderInfo(url: source, fileCount: files, totalSize: bytes,
                                lastModified: finished, isInternalDrive: false)
        return TransferCard(
            source: folder,
            destinations: [FolderInfo(url: URL(fileURLWithPath: "/Volumes/Backup/\(roll)"), fileCount: files,
                                      totalSize: bytes, lastModified: finished, isInternalDrive: false)],
            cameraCard: CameraCard(
                name: camera, manufacturer: "Unknown", model: camera, fileCount: files, totalSize: bytes,
                detectionConfidence: 0.95, metadata: [:], volumeURL: source, cameraType: .generic, mediaPath: source
            ),
            metadata: TransferMetadata(
                sourceURL: source, destinationURLs: [], startTime: finished.addingTimeInterval(-60),
                endTime: finished, totalFiles: files, totalSize: bytes,
                verificationMode: verified ? .standard : .quick, cameraSettings: nil
            ),
            progress: 1,
            state: .completed(OperationCompletionInfo(success: verified, message: verified ? "Verified" : "Not verified"))
        )
    }

    private func fakeResult() -> MasterReportResult {
        let configuration = SharedReportGenerationService.ReportConfiguration.default()
        return MasterReportResult(
            pdfData: Data("pdf".utf8),
            jsonData: Data("{}".utf8),
            reportData: ReportData(
                configuration: configuration,
                generatedAt: Date(),
                summary: .init(totalTransfers: 0, totalFiles: 0, totalSize: 0, formattedSize: "0", verificationRate: 0),
                cameraGroups: [],
                allTransfers: []
            ),
            generatedAt: Date()
        )
    }

    private struct WriteFailed: Error {}

    /// A model that has scanned `cards` from a fake folder.
    private func scannedModel(_ cards: [TransferCard]) async -> MasterReportModel {
        let model = MasterReportModel(
            scanner: { _, _ in ReportScanner.ScanResult(cards: cards, skipped: []) },
            renderer: { [self] _, _ in fakeResult() }
        )
        await model.choose(URL(fileURLWithPath: "/Volumes/Backup"))?.value
        return model
    }

    // MARK: - Grouping

    @Test func zeroByteMasterReportTotalsUseEmptyWording() {
        let totals = MasterReportPresentation.totals([
            card(camera: "FX6", roll: "A001", files: 1, bytes: 0)
        ])
        #expect(totals.sizeText == "Empty")
        #expect(!totals.sizeText.contains("Zero KB"))
    }

    @Test func nonVerifiedMasterReportCardWarnsNotToErase() {
        let unverified = card(camera: "FX6", roll: "A001", verified: false)
        #expect(MasterReportPresentation.statusText(for: unverified) == "Not verified — do not erase the card")
        #expect(MasterReportPresentation.statusText(for: card(camera: "FX6", roll: "A002")) == "Verified")
    }

    /// Plant: in `MasterReportPresentation.groups`, return one flat group:
    /// `[MasterReportCameraGroup(name: "All", cards: cards)]`.
    @Test func groupsByCamera() throws {
        let day = Date()
        let cards = [
            card(camera: "FX6", roll: "A002", files: 5, bytes: 500, finished: day.addingTimeInterval(120)),
            card(camera: "Alexa", roll: "B001", verified: false, files: 7, bytes: 700, finished: day),
            card(camera: "FX6", roll: "A001", files: 3, bytes: 300, finished: day),
        ]

        let groups = MasterReportPresentation.groups(cards)

        #expect(groups.map(\.name) == ["Alexa", "FX6"])
        let fx6 = try #require(groups.last)
        #expect(fx6.cards.map(\.source.name) == ["A001", "A002"])
        #expect(fx6.totalFiles == 8)
        #expect(fx6.totalSize == 800)
        #expect(fx6.verifiedCount == 2)
        #expect(groups.first?.verifiedCount == 0)
    }

    // MARK: - Generating

    /// Plant: in `MasterReportModel.generate`, replace
    /// `guard let delivery = try await deliver(...) else { ... }` with
    /// `let delivery = (try? await deliver(...)) ?? .shared`, so a failed or
    /// cancelled write still reads as a success.
    @Test func successOnlyAfterWrite() async {
        let model = await scannedModel([card(camera: "FX6", roll: "A001")])
        let configuration = SharedReportGenerationService.ReportConfiguration.default()

        var stateDuringWrite: MasterReportModel.Generation?
        await model.generate(configuration: configuration) { _, _ in
            stateDuringWrite = model.generation
            throw WriteFailed()
        }
        #expect(stateDuringWrite == .generating)
        guard case .failed = model.generation else {
            Issue.record("A failed write must not read as saved: \(model.generation)")
            return
        }

        await model.generate(configuration: configuration) { _, _ in nil }
        #expect(model.generation == .idle, "A cancelled save panel or share sheet is not a success")

        let saved = URL(fileURLWithPath: "/tmp/MasterReport.pdf")
        await model.generate(configuration: configuration) { _, _ in .saved(saved) }
        #expect(model.generation == .delivered(.saved(saved)))
    }

    /// Plant: in `MasterReportPresentation.make`, delete the
    /// `if selectedCount == 0 { ... }` branch.
    @Test func generateNeedsASelection() async throws {
        let model = await scannedModel([card(camera: "FX6", roll: "A001")])
        #expect(model.presentation(deliverVerb: "Save").canGenerate)
        #expect(model.presentation(deliverVerb: "Save").actionTitle == "Create Master Report")

        model.setGroup(try #require(model.groups.first), included: false)

        let presentation = model.presentation(deliverVerb: "Save")
        #expect(!presentation.canGenerate)
        #expect(presentation.nextStep == .selectTransfers)
        #expect(presentation.actionTitle == "Select transfers to include")
    }

    /// Plant: in `MasterReportPresentation.make`, return `nextStep: nil` for
    /// the `!hasLocation` case.
    @Test func noLocationNamesTheStep() {
        let model = MasterReportModel(scanner: { _, _ in ReportScanner.ScanResult(cards: [], skipped: []) })
        let presentation = model.presentation(deliverVerb: "Share")
        #expect(!presentation.canGenerate)
        #expect(presentation.nextStep == .chooseLocation)
        #expect(presentation.actionTitle == "Choose a drive to scan")
    }

    // MARK: - Scanning

    /// Changing the day scans again, and a slower scan for the old day that
    /// finishes last never replaces the new day's results.
    /// Plant: in `MasterReportModel.scan`, delete
    /// `guard let self, self.activeScanID == scanID else { return }` down to
    /// `guard let self else { return }`.
    @Test func staleScanIsIgnored() async {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let oldCard = card(camera: "FX6", roll: "OLD")
        let newCard = card(camera: "FX6", roll: "NEW")
        var scannedDays: [Date] = []

        let model = MasterReportModel(
            day: today,
            calendar: calendar,
            scanner: { _, day in
                scannedDays.append(day)
                if calendar.isDate(day, inSameDayAs: today) {
                    // The first scan is slow, ignores cancellation (as a long
                    // directory walk between checks does), and ends last.
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.resume() }
                    }
                    return ReportScanner.ScanResult(cards: [oldCard], skipped: [])
                }
                return ReportScanner.ScanResult(cards: [newCard], skipped: [])
            }
        )

        let first = model.choose(URL(fileURLWithPath: "/Volumes/Backup"))
        model.day = yesterday
        let second = model.currentScan
        await second?.value
        // Let the superseded scan finish too, after the newer one.
        await first?.value

        #expect(scannedDays.count == 2)
        #expect(model.phase == .scanned)
        #expect(model.cards.map(\.source.name) == ["NEW"])
        #expect(model.selection == Set([newCard.id]))
    }
}
