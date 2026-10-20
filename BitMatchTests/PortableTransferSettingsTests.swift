import Foundation
import Darwin
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
@Suite(.serialized)
struct PortableTransferSettingsTests {
    private final class Fixture {
        let name = "BitMatchTests.PortableSettings.\(UUID())"
        let defaults: UserDefaults
        let folders: CoordinatorFolders
        let coordinator: SharedAppCoordinator
        @MainActor init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            folders = try CoordinatorFolders()
            coordinator = SharedAppCoordinator(platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
                transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
                projectStore: InMemoryPhotographerJobStore(), defaults: defaults)
        }
        deinit { defaults.removePersistentDomain(forName: name); folders.cleanup() }
    }

    private func changed(_ current: PortableTransferSettings) -> PortableTransferSettings {
        .init(verificationMode: .quick, generateASCMHL: !current.generateASCMHL,
            ignoreAppleDouble: !current.ignoreAppleDouble,
            reports: .init(makeReport: !current.reports.makeReport, includeThumbnails: !current.reports.includeThumbnails),
            naming: .init(position: .suffix, separator: .dash, autoNumber: !current.naming.autoNumber,
                groupByCamera: !current.naming.groupByCamera))
    }

    @Test func roundTripHasOnlyTheApprovedFieldsAndNoPrivateValues() throws {
        let fixture = try Fixture()
        let app = fixture.coordinator
        app.reportSettings.clientName = "PRIVATE_CLIENT"
        app.reportSettings.projectName = "PRIVATE_PROJECT"
        app.reportSettings.production = "PRIVATE_PRODUCTION"
        app.reportSettings.company = "PRIVATE_COMPANY"
        app.reportSettings.operatorName = "PRIVATE_OPERATOR"
        app.reportSettings.notes = "PRIVATE_NOTES"
        app.cameraLabels.settings.label = "PRIVATE_CAMERA"
        app.cameraLabels.settings.destinationPathComponents = ["PRIVATE_ROUTE"]
        fixture.defaults.set("PRIVATE_TOKEN", forKey: "unrelatedCredential")
        app.sourceURL = fixture.folders.source
        app.destinationURLs = [fixture.folders.primary]
        let original = app.portableTransferSettings
        let data = try original.encoded()
        #expect(try PortableTransferSettings.decode(data) == original)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("PRIVATE_"))
        #expect(!text.contains(fixture.folders.root.path))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "schemaVersion", "verificationMode", "generateASCMHL", "ignoreAppleDouble", "reports", "naming"])
        let report = try #require(object["reports"] as? [String: Any])
        #expect(Set(report.keys) == ["makeReport", "includeThumbnails"])
        let naming = try #require(object["naming"] as? [String: Any])
        #expect(Set(naming.keys) == ["position", "separator", "autoNumber", "groupByCamera"])
        #expect(data.count < PortableTransferSettings.maximumBytes)
    }

    @Test(arguments: ["malformed", "format", "future", "version-type", "missing", "mode", "bool", "unknown", "private-nested", "private-naming", "naming", "null"])
    func invalidFilesNeverChangeSettings(kind: String) throws {
        let fixture = try Fixture()
        let original = fixture.coordinator.portableTransferSettings
        var object = try #require(JSONSerialization.jsonObject(with: changed(original).encoded()) as? [String: Any])
        switch kind {
        case "format": object["format"] = "Another settings file"
        case "future": object["schemaVersion"] = 999
        case "version-type": object["schemaVersion"] = "1"
        case "missing": object.removeValue(forKey: "ignoreAppleDouble")
        case "mode": object["verificationMode"] = "SUPER FAST"
        case "bool": object["generateASCMHL"] = 1
        case "unknown": object["destinations"] = ["/Volumes/private"]
        case "private-nested": object["reports"] = ["makeReport": true, "includeThumbnails": false, "notes": "private"]
        case "private-naming":
            var naming = try #require(object["naming"] as? [String: Any])
            naming["label"] = "private camera"
            object["naming"] = naming
        case "naming": object["naming"] = ["position": "Sideways", "separator": "_", "autoNumber": true, "groupByCamera": false]
        case "null": object["reports"] = NSNull()
        default: break
        }
        let data = kind == "malformed" ? Data("{\"broken\":".utf8) : try JSONSerialization.data(withJSONObject: object)
        let model = TransferSettingsImportModel()
        #expect(throws: (any Error).self) { try model.preview(data, coordinator: fixture.coordinator) }
        #expect(model.review == nil)
        #expect(fixture.coordinator.portableTransferSettings == original)
        #expect(ReportPrefsStore(defaults: fixture.defaults).load().makeReport == original.reports.makeReport)
    }

    @Test func oversizedAndSpecialFilesAreRejectedBeforeUnboundedReads() throws {
        let fixture = try Fixture()
        let file = fixture.folders.root.appendingPathComponent("settings.json")
        #expect(throws: TransferSettingsImportError.invalidFile) {
            _ = try TransferSettingsFileReader.read(URL(string: "https://example.com/settings.json")!)
        }
        #expect(throws: TransferSettingsImportError.tooLarge) {
            _ = try PortableTransferSettings.decode(Data(repeating: 32, count: PortableTransferSettings.maximumBytes + 1))
        }
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try handle.close()
        #expect(throws: TransferSettingsImportError.tooLarge) { _ = try TransferSettingsFileReader.read(file) }
        let pipe = fixture.folders.root.appendingPathComponent("pipe.json")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: TransferSettingsImportError.invalidFile) { _ = try TransferSettingsFileReader.read(pipe) }
        let link = fixture.folders.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { _ = try TransferSettingsFileReader.read(link) }
    }

    @Test func boundedReaderAcceptsAValidFileAtItsSizeLimit() throws {
        let fixture = try Fixture()
        let proposal = changed(fixture.coordinator.portableTransferSettings)
        var data = try proposal.encoded()
        data.append(Data(repeating: 32, count: PortableTransferSettings.maximumBytes - data.count))
        let file = fixture.folders.root.appendingPathComponent("settings.json")
        try data.write(to: file)
        let loaded = try TransferSettingsFileReader.read(file)
        #expect(loaded.count == PortableTransferSettings.maximumBytes)
        #expect(try PortableTransferSettings.decode(loaded) == proposal)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test(arguments: VerificationMode.allCases, CameraLabelSettings.Separator.allCases)
    func allModesAndSeparatorsRoundTrip(mode: VerificationMode, separator: CameraLabelSettings.Separator) throws {
        let settings = PortableTransferSettings(verificationMode: mode, generateASCMHL: false, ignoreAppleDouble: false,
            reports: .init(makeReport: true, includeThumbnails: false),
            naming: .init(position: .suffix, separator: separator, autoNumber: true, groupByCamera: true))
        #expect(try PortableTransferSettings.decode(settings.encoded()) == settings)
    }

    @Test func previewAndCancelDoNotApplyAnything() throws {
        let fixture = try Fixture()
        let original = fixture.coordinator.portableTransferSettings
        let model = TransferSettingsImportModel()
        try model.preview(changed(original).encoded(), coordinator: fixture.coordinator)
        #expect(model.review?.changes.count == 9)
        #expect(fixture.coordinator.portableTransferSettings == original)
        model.cancel()
        #expect(model.review == nil)
        #expect(fixture.coordinator.portableTransferSettings == original)
        #expect(throws: TransferSettingsImportError.invalidFile) { try model.apply(to: fixture.coordinator) }
    }

    @Test func applyPersistsOnlyApprovedFieldsAndRetainsPrivateSettings() throws {
        let fixture = try Fixture()
        let app = fixture.coordinator
        app.reportSettings.clientName = "Keep client"
        app.reportSettings.operatorName = "Keep operator"
        app.reportSettings.notes = "Keep notes"
        app.reportSettings.enableAutoCameraDetection = false
        app.cameraLabels.settings.label = "Keep camera"
        app.cameraLabels.settings.destinationPathComponents = ["Keep", "route"]
        let destinations = app.destinationURLs
        let general = app.generalSettings.collectLocalCrashEvidence
        let original = app.portableTransferSettings
        let proposed = changed(original)
        let model = TransferSettingsImportModel()
        try model.preview(proposed.encoded(), coordinator: app)
        try model.apply(to: app)
        #expect(model.review == nil)
        #expect(app.portableTransferSettings == proposed)
        #expect(app.reportSettings.clientName == "Keep client")
        #expect(app.reportSettings.operatorName == "Keep operator")
        #expect(app.reportSettings.notes == "Keep notes")
        #expect(!app.reportSettings.enableAutoCameraDetection)
        #expect(app.cameraLabels.settings.label == "Keep camera")
        #expect(app.cameraLabels.settings.destinationPathComponents == ["Keep", "route"])
        #expect(app.destinationURLs == destinations)
        #expect(app.sourceURL == nil)
        #expect(app.generalSettings.collectLocalCrashEvidence == general)
        let saved = SharedAppCoordinator(platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: fixture.folders.root.appendingPathComponent("relaunch.json")),
            projectStore: InMemoryPhotographerJobStore(), defaults: fixture.defaults)
        #expect(saved.portableTransferSettings == proposed)
        #expect(saved.reportSettings.notes == "Keep notes")
        #expect(saved.cameraLabels.settings.label == "Keep camera")
    }

    @Test func applyRechecksActiveWorkAndQueueWithoutChangingRecordedCards() throws {
        let fixture = try Fixture()
        let app = fixture.coordinator
        let original = app.portableTransferSettings
        let model = TransferSettingsImportModel()
        try model.preview(changed(original).encoded(), coordinator: app)
        app.isOperationInProgress = true
        #expect(throws: TransferSettingsImportError.busy) { try model.apply(to: app) }
        #expect(app.portableTransferSettings == original)
        app.isOperationInProgress = false
        let id = try app.transferJournal.enqueue(sourceURL: fixture.folders.source, destinationURLs: [fixture.folders.primary],
            verificationMode: .thorough, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(app.transferJournal.records.first { $0.id == id })
        // A waiting journal card is a queue record even before a session starts.
        #expect(throws: TransferSettingsImportError.busy) { try model.apply(to: app) }
        #expect(app.portableTransferSettings == original)
        #expect(try encoder.encode(app.transferJournal.records.first { $0.id == id }) == before)
    }

    @Test func changedPreferencesRequireANewPreview() throws {
        let fixture = try Fixture()
        let app = fixture.coordinator
        let model = TransferSettingsImportModel()
        try model.preview(changed(app.portableTransferSettings).encoded(), coordinator: app)
        app.reportSettings.includeThumbnails.toggle()
        let current = app.portableTransferSettings
        #expect(throws: TransferSettingsImportError.settingsChanged) { try model.apply(to: app) }
        #expect(app.portableTransferSettings == current)
    }

    @Test func preparedProjectCardBlocksApplyAndStaysUntouched() throws {
        let fixture = try Fixture()
        let app = fixture.coordinator
        let model = TransferSettingsImportModel()
        try model.preview(changed(app.portableTransferSettings).encoded(), coordinator: app)
        let jobs = app.photographerJobViewModel
        jobs.createWeddingJob(clientName: "Keep client", jobName: "Keep job", eventDate: Date(timeIntervalSince1970: 0))
        try jobs.prepareCard(photographerName: "Keep operator", cameraName: "Keep camera",
            analysis: CardAnalysis(fingerprint: "owned-fixture", fileCount: 1, totalBytes: 4,
                companionGroups: [], sourcePaths: [fixture.folders.source.appendingPathComponent("A.ARW").path]))
        #expect(jobs.hasPreparedIngestAwaitingStart)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(jobs.activeJob)
        let settings = app.portableTransferSettings
        #expect(throws: TransferSettingsImportError.busy) { try model.apply(to: app) }
        #expect(app.portableTransferSettings == settings)
        #expect(try encoder.encode(jobs.activeJob) == before)
    }

    @Test func selectedSourceIsRetainedAndAppleDoubleReviewStartsAgain() throws {
        let fixture = try Fixture()
        let app = fixture.coordinator
        app.appleDoubleSelection.enabled = false
        app.sourceURL = fixture.folders.source
        let original = app.portableTransferSettings
        let proposed = changed(original)
        let model = TransferSettingsImportModel()
        try model.preview(proposed.encoded(), coordinator: app)
        try model.apply(to: app)
        #expect(app.sourceURL == fixture.folders.source)
        #expect(app.appleDoubleSelection.enabled)
        #expect(app.appleDoubleSelection.paths == nil)
        #expect(app.appleDoubleSelection.isReviewing)
        #expect(!app.canStartOperation)
    }
}
