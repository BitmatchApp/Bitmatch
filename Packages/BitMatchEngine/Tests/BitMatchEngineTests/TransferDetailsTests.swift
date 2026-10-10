import Foundation
import Testing
@testable import BitMatchEngine

struct TransferDetailsTests {
    @Test func olderSettingsKeepTheirValuesWhenNewFieldsAreAbsent() throws {
        let original = ReportPrefs(clientName: "Client", notes: "Existing notes", makeReport: false,
                                   autoPopulateSource: false, checksumAlgorithm: .md5)
        let data = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "operatorName")
        json.removeValue(forKey: "includeThumbnails")
        let restored = try JSONDecoder().decode(ReportPrefs.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.operatorName.isEmpty)
        #expect(!restored.includeThumbnails)
        #expect(restored.notes == "Existing notes")
        #expect(restored.clientName == "Client")
        #expect(!restored.makeReport)
        #expect(!restored.autoPopulateSource)
        #expect(restored.checksumAlgorithm == .md5)
    }

    @Test func journalKeepsPerTransferDetailsAfterSettingsChangeAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("details-journal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("journal.json")
        var journal: TransferJournal? = TransferJournal(fileURL: url)
        var prefs = ReportPrefs(notes: "Card one", operatorName: "Alex")
        let first = try journal!.enqueue(sourceURL: source, destinationURLs: [destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: prefs, generateASCMHL: true)
        prefs.notes = "Card two"; prefs.operatorName = "Sam"
        _ = try journal!.enqueue(sourceURL: source, destinationURLs: [destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: prefs, generateASCMHL: true)
        journal = nil // A relaunched instance must acquire the real journal lock.
        let restored = TransferJournal(fileURL: url)
        let record = try #require(restored.records.first { $0.id == first })
        #expect(record.reportSettings.notes == "Card one")
        #expect(record.reportSettings.operatorName == "Alex")
    }
}
