import Foundation
import BitMatchEngine

/// A whitelist of reusable choices, separate from stored reports and jobs.
/// Names, paths, permissions, identities and transfer evidence never enter it.
struct PortableTransferSettings: Codable, Equatable, Sendable {
    static let format = "BitMatch transfer settings"
    static let schemaVersion = 1
    static let maximumBytes = 16 * 1_024

    let verificationMode: VerificationMode
    let generateASCMHL: Bool
    let ignoreAppleDouble: Bool
    let reports: Reports
    let naming: Naming

    struct Reports: Codable, Equatable, Sendable {
        let makeReport: Bool
        let includeThumbnails: Bool
        init(makeReport: Bool, includeThumbnails: Bool) {
            self.makeReport = makeReport
            self.includeThumbnails = includeThumbnails
        }
        private enum CodingKeys: String, CodingKey, CaseIterable { case makeReport, includeThumbnails }
        init(from decoder: Decoder) throws {
            try rejectUnknownSettingsKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            makeReport = try values.decode(Bool.self, forKey: .makeReport)
            includeThumbnails = try values.decode(Bool.self, forKey: .includeThumbnails)
        }
    }

    struct Naming: Codable, Equatable, Sendable {
        let position: CameraLabelSettings.LabelPosition
        let separator: CameraLabelSettings.Separator
        let autoNumber: Bool
        let groupByCamera: Bool
        init(position: CameraLabelSettings.LabelPosition, separator: CameraLabelSettings.Separator,
             autoNumber: Bool, groupByCamera: Bool) {
            self.position = position
            self.separator = separator
            self.autoNumber = autoNumber
            self.groupByCamera = groupByCamera
        }
        private enum CodingKeys: String, CodingKey, CaseIterable { case position, separator, autoNumber, groupByCamera }
        init(from decoder: Decoder) throws {
            try rejectUnknownSettingsKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            position = try values.decode(CameraLabelSettings.LabelPosition.self, forKey: .position)
            separator = try values.decode(CameraLabelSettings.Separator.self, forKey: .separator)
            autoNumber = try values.decode(Bool.self, forKey: .autoNumber)
            groupByCamera = try values.decode(Bool.self, forKey: .groupByCamera)
        }
    }

    init(verificationMode: VerificationMode, generateASCMHL: Bool, ignoreAppleDouble: Bool,
         reports: Reports, naming: Naming) {
        self.verificationMode = verificationMode
        self.generateASCMHL = generateASCMHL
        self.ignoreAppleDouble = ignoreAppleDouble
        self.reports = reports
        self.naming = naming
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, schemaVersion, verificationMode, generateASCMHL, ignoreAppleDouble, reports, naming
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == Self.format else {
            throw TransferSettingsImportError.invalidFile
        }
        guard try values.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw TransferSettingsImportError.unsupportedVersion
        }
        try rejectUnknownSettingsKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        verificationMode = try values.decode(VerificationMode.self, forKey: .verificationMode)
        generateASCMHL = try values.decode(Bool.self, forKey: .generateASCMHL)
        ignoreAppleDouble = try values.decode(Bool.self, forKey: .ignoreAppleDouble)
        reports = try values.decode(Reports.self, forKey: .reports)
        naming = try values.decode(Naming.self, forKey: .naming)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.format, forKey: .format)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(verificationMode, forKey: .verificationMode)
        try values.encode(generateASCMHL, forKey: .generateASCMHL)
        try values.encode(ignoreAppleDouble, forKey: .ignoreAppleDouble)
        try values.encode(reports, forKey: .reports)
        try values.encode(naming, forKey: .naming)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw TransferSettingsImportError.tooLarge }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch let error as TransferSettingsImportError { throw error }
        catch { throw TransferSettingsImportError.invalidFile }
    }

    struct Change: Identifiable, Equatable, Sendable {
        let title: String
        let before: String
        let after: String
        var id: String { title }
    }

    func changes(from current: Self) -> [Change] {
        var result: [Change] = []
        func add(_ title: String, _ before: String, _ after: String) {
            if before != after { result.append(Change(title: title, before: before, after: after)) }
        }
        func onOff(_ value: Bool) -> String { value ? "On" : "Off" }
        add("Verification", current.verificationMode.rawValue, verificationMode.rawValue)
        add("ASC MHL", onOff(current.generateASCMHL), onOff(generateASCMHL))
        add("Ignore AppleDouble metadata", onOff(current.ignoreAppleDouble), onOff(ignoreAppleDouble))
        add("Reports", onOff(current.reports.makeReport), onOff(reports.makeReport))
        add("PDF clip thumbnails", onOff(current.reports.includeThumbnails), onOff(reports.includeThumbnails))
        add("Label position", current.naming.position.rawValue, naming.position.rawValue)
        add("Separator", current.naming.separator.displayName, naming.separator.displayName)
        add("Auto-number folders", onOff(current.naming.autoNumber), onOff(naming.autoNumber))
        add("Group by camera", onOff(current.naming.groupByCamera), onOff(naming.groupByCamera))
        return result
    }
}

enum TransferSettingsImportError: LocalizedError, Equatable {
    case invalidFile, unsupportedVersion, tooLarge, busy, settingsChanged
    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a transfer settings JSON file exported by BitMatch."
        case .unsupportedVersion: "This settings file needs a different version of BitMatch."
        case .tooLarge: "This file is too large to be a transfer settings file."
        case .busy: "Finish current or queued work before importing settings."
        case .settingsChanged: "Settings changed while this preview was open. Import the file again to review the changes."
        }
    }
}

private struct SettingsCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownSettingsKeys(_ decoder: Decoder, allowed: [String]) throws {
    let values = try decoder.container(keyedBy: SettingsCodingKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else {
        throw TransferSettingsImportError.invalidFile
    }
}
