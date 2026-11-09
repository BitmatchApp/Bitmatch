import Foundation
import BitMatchEngine

/// A whitelist of reusable choices, separate from stored reports and jobs.
/// Names, paths, permissions, identities and transfer evidence never enter it.
struct PortableTransferSettings: Codable, Equatable, Sendable {
    static let format = "BitMatch transfer settings"
    static let schemaVersion = 2
    static let maximumBytes = 16 * 1_024

    let verificationMode: VerificationMode
    let generateASCMHL: Bool
    let ignoreAppleDouble: Bool
    let reports: Reports
    let naming: Naming
    /// Recipe layers only. Preset names, IDs and project metadata stay local.
    let folderRecipes: [Recipe]?

    struct Recipe: Codable, Equatable, Sendable {
        struct Layer: Codable, Equatable, Sendable {
            let kind: FolderLayerKind
            let isEnabled: Bool

            private enum CodingKeys: String, CodingKey, CaseIterable { case kind, isEnabled }

            init(kind: FolderLayerKind, isEnabled: Bool) {
                self.kind = kind
                self.isEnabled = isEnabled
            }

            init(from decoder: Decoder) throws {
                try rejectUnknownSettingsKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
                let values = try decoder.container(keyedBy: CodingKeys.self)
                kind = try values.decode(FolderLayerKind.self, forKey: .kind)
                isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
            }
        }

        let layers: [Layer]

        var isValid: Bool {
            !layers.isEmpty && layers.count <= FolderLayerKind.allCases.count
                && Set(layers.map(\.kind)).count == layers.count
        }

        init(layers: [Layer]) { self.layers = layers }

        private enum CodingKeys: String, CodingKey, CaseIterable { case layers }

        init(from decoder: Decoder) throws {
            try rejectUnknownSettingsKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
            let values = try decoder.container(keyedBy: CodingKeys.self)
            layers = try values.decode([Layer].self, forKey: .layers)
            guard isValid else { throw TransferSettingsImportError.invalidFile }
        }
    }

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
         reports: Reports, naming: Naming, folderRecipes: [Recipe]? = nil) {
        self.verificationMode = verificationMode
        self.generateASCMHL = generateASCMHL
        self.ignoreAppleDouble = ignoreAppleDouble
        self.reports = reports
        self.naming = naming
        self.folderRecipes = folderRecipes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, schemaVersion, verificationMode, generateASCMHL, ignoreAppleDouble, reports, naming, folderRecipes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .format) == Self.format else {
            throw TransferSettingsImportError.invalidFile
        }
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == Self.schemaVersion else {
            throw TransferSettingsImportError.unsupportedVersion
        }
        try rejectUnknownSettingsKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        if version == 1, values.contains(.folderRecipes) { throw TransferSettingsImportError.invalidFile }
        verificationMode = try values.decode(VerificationMode.self, forKey: .verificationMode)
        generateASCMHL = try values.decode(Bool.self, forKey: .generateASCMHL)
        ignoreAppleDouble = try values.decode(Bool.self, forKey: .ignoreAppleDouble)
        reports = try values.decode(Reports.self, forKey: .reports)
        naming = try values.decode(Naming.self, forKey: .naming)
        if version == 1 {
            folderRecipes = nil
        } else {
            let recipes = try values.decode([Recipe].self, forKey: .folderRecipes)
            guard recipes.count <= 32 else { throw TransferSettingsImportError.invalidFile }
            folderRecipes = recipes
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.format, forKey: .format)
        try values.encode(folderRecipes == nil ? 1 : Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(verificationMode, forKey: .verificationMode)
        try values.encode(generateASCMHL, forKey: .generateASCMHL)
        try values.encode(ignoreAppleDouble, forKey: .ignoreAppleDouble)
        try values.encode(reports, forKey: .reports)
        try values.encode(naming, forKey: .naming)
        try values.encodeIfPresent(folderRecipes, forKey: .folderRecipes)
    }

    func encoded() throws -> Data {
        if let folderRecipes {
            guard folderRecipes.count <= 32 else { throw TransferSettingsImportError.tooManyRecipes }
            guard folderRecipes.allSatisfy(\.isValid) else { throw TransferSettingsImportError.invalidRecipe }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw TransferSettingsImportError.tooLarge }
        return data
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
        if let folderRecipes {
            let existing = current.folderRecipes ?? []
            let additions = folderRecipes.reduce(into: [Recipe]()) { result, recipe in
                if !existing.contains(recipe) && !result.contains(recipe) { result.append(recipe) }
            }
            if !additions.isEmpty {
                add("Folder recipes", "\(existing.count) saved", "\(existing.count + additions.count) saved")
            }
        }
        return result
    }
}

enum TransferSettingsImportError: LocalizedError, Equatable {
    case invalidFile, unsupportedVersion, tooLarge, busy, settingsChanged, tooManyRecipes, invalidRecipe
    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a transfer settings JSON file exported by BitMatch."
        case .unsupportedVersion: "This settings file needs a different version of BitMatch."
        case .tooLarge: "This file is too large to be a transfer settings file."
        case .busy: "Finish current or queued work before importing settings."
        case .settingsChanged: "Settings changed while this preview was open. Import the file again to review the changes."
        case .tooManyRecipes: "This settings file supports up to 32 saved folder recipes."
        case .invalidRecipe: "A saved folder recipe has unsupported or duplicate layers."
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
