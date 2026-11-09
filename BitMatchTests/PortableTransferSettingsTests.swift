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
        let projectStore: InMemoryPhotographerJobStore
        @MainActor init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            folders = try CoordinatorFolders()
            projectStore = InMemoryPhotographerJobStore()
            coordinator = SharedAppCoordinator(platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
                transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
                projectStore: projectStore, defaults: defaults)
        }
        deinit { defaults.removePersistentDomain(forName: name); folders.cleanup() }
    }

    @Test func recipeStructuresTravelWithoutPresetNamesOrAutomaticSelection() throws {
        let source = try Fixture()
        let target = try Fixture()
        source.coordinator.photographerJobViewModel.saveDraftAsPreset(name: "PRIVATE_CLIENT_RECIPE")
        let exported = try source.coordinator.portableTransferSettingsForExport().encoded()
        #expect(!String(decoding: exported, as: UTF8.self).contains("PRIVATE_CLIENT_RECIPE"))
        let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let recipes = try #require(object["folderRecipes"] as? [[String: Any]])
        #expect(recipes.allSatisfy { Set($0.keys) == ["layers"] })
        let layers = try #require(recipes.first?["layers"] as? [[String: Any]])
        #expect(layers.allSatisfy { Set($0.keys) == ["kind", "isEnabled"] })
        let preset = try #require(source.projectStore.storedPresets.first)
        #expect(!String(decoding: exported, as: UTF8.self).contains(preset.id.uuidString))
        for layer in preset.recipe.layers {
            #expect(!String(decoding: exported, as: UTF8.self).contains(layer.id.uuidString))
        }
        let originalDraft = target.coordinator.photographerJobViewModel.draftRecipe
        let model = TransferSettingsImportModel()
        try model.preview(exported, coordinator: target.coordinator)
        #expect(model.review?.changes.contains(where: { $0.title == "Folder recipes" }) == true)
        try model.apply(to: target.coordinator)
        #expect(target.projectStore.storedPresets.count == 1)
        #expect(target.projectStore.storedPresets[0].name == "Imported recipe 1")
        #expect(target.coordinator.photographerJobViewModel.draftRecipe == originalDraft)
        #expect(target.coordinator.photographerJobViewModel.portableFolderRecipes
            == source.coordinator.photographerJobViewModel.portableFolderRecipes)
        try model.preview(exported, coordinator: target.coordinator)
        #expect(model.review?.changes.isEmpty == true)
    }

    @Test func legacySettingsLeaveExistingRecipesAlone() throws {
        let target = try Fixture()
        target.coordinator.photographerJobViewModel.saveDraftAsPreset(name: "Existing")
        let before = target.projectStore.storedPresets
        let model = TransferSettingsImportModel()
        try model.preview(changed(target.coordinator.portableTransferSettings).encoded(), coordinator: target.coordinator)
        try model.apply(to: target.coordinator)
        #expect(target.projectStore.storedPresets == before)
    }

    @Test func importAddsDistinctRecipesOnlyAndPreservesExistingPresets() throws {
        let target = try Fixture()
        target.coordinator.photographerJobViewModel.saveDraftAsPreset(name: "Existing")
        let before = target.projectStore.storedPresets
        let existing = try #require(target.coordinator.photographerJobViewModel.portableFolderRecipes.first)
        let newRecipe = PortableTransferSettings.Recipe(layers: [.init(kind: .cardNumber, isEnabled: true)])
        let base = target.coordinator.portableTransferSettings
        let proposal = PortableTransferSettings(verificationMode: base.verificationMode,
            generateASCMHL: base.generateASCMHL, ignoreAppleDouble: base.ignoreAppleDouble,
            reports: base.reports, naming: base.naming, folderRecipes: [existing, newRecipe, newRecipe])
        let model = TransferSettingsImportModel()
        try model.preview(proposal.encoded(), coordinator: target.coordinator)
        #expect(model.review?.changes.first(where: { $0.title == "Folder recipes" })?.after == "2 saved")
        try model.apply(to: target.coordinator)
        #expect(target.projectStore.storedPresets.count == 2)
        #expect(target.projectStore.storedPresets.contains(before[0]))
        #expect(target.coordinator.photographerJobViewModel.portableFolderRecipes.contains(newRecipe))
    }

    @Test(arguments: ["unknown-recipe", "unknown-layer", "duplicate-layer", "empty", "too-many", "version-one"])
    func malformedRecipeFilesAreRejected(kind: String) throws {
        let fixture = try Fixture()
        fixture.coordinator.photographerJobViewModel.saveDraftAsPreset(name: "Source")
        let data = try fixture.coordinator.portableTransferSettingsForExport().encoded()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var recipes = try #require(object["folderRecipes"] as? [[String: Any]])
        var layers = try #require(recipes[0]["layers"] as? [[String: Any]])
        switch kind {
        case "unknown-recipe": recipes[0]["name"] = "private"
        case "unknown-layer": layers[0]["path"] = "/private"; recipes[0]["layers"] = layers
        case "duplicate-layer": layers.append(layers[0]); recipes[0]["layers"] = layers
        case "empty": recipes[0]["layers"] = []
        case "too-many": recipes = Array(repeating: recipes[0], count: 33)
        case "version-one": object["schemaVersion"] = 1
        default: break
        }
        object["folderRecipes"] = recipes
        let altered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { _ = try PortableTransferSettings.decode(altered) }
    }

    @Test func recipeStoreFailureLeavesSettingsAndPresetsUnchanged() throws {
        let source = try Fixture()
        let target = try Fixture()
        source.coordinator.photographerJobViewModel.saveDraftAsPreset(name: "Source recipe")
        source.coordinator.generateASCMHL = !target.coordinator.generateASCMHL
        let exported = try source.coordinator.portableTransferSettingsForExport().encoded()
        let original = target.coordinator.portableTransferSettings
        let model = TransferSettingsImportModel()
        try model.preview(exported, coordinator: target.coordinator)
        target.projectStore.errorOnSave = PortableRecipeImportError.unavailable
        #expect(throws: (any Error).self) { try model.apply(to: target.coordinator) }
        #expect(target.projectStore.storedPresets.isEmpty)
        #expect(target.coordinator.portableTransferSettings == original)
        #expect(model.review != nil)
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

    @Test func interruptedImportRollsForwardOnNextLaunch() throws {
        let fixture = try Fixture()
        let proposed = changed(fixture.coordinator.portableTransferSettings)
        // Simulate termination after the pending record was written but
        // before the import committed: only the record survives.
        fixture.defaults.set(try proposed.encoded(),
            forKey: SharedAppCoordinator.pendingTransferSettingsImportKey)
        let relaunched = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: fixture.folders.root.appendingPathComponent("relaunch.json")),
            projectStore: InMemoryPhotographerJobStore(), defaults: fixture.defaults)
        #expect(relaunched.portableTransferSettings == proposed)
        #expect(fixture.defaults.data(forKey: SharedAppCoordinator.pendingTransferSettingsImportKey) == nil)
    }

    @Test func failedImportKeepsPendingRecordForNextLaunch() throws {
        let source = try Fixture()
        let target = try Fixture()
        source.coordinator.photographerJobViewModel.saveDraftAsPreset(name: "Source recipe")
        let exported = try source.coordinator.portableTransferSettingsForExport().encoded()
        let model = TransferSettingsImportModel()
        try model.preview(exported, coordinator: target.coordinator)
        target.projectStore.errorOnSave = PortableRecipeImportError.unavailable
        #expect(throws: (any Error).self) { try model.apply(to: target.coordinator) }
        #expect(target.defaults.data(forKey: SharedAppCoordinator.pendingTransferSettingsImportKey) != nil)
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
