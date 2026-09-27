import Foundation
import Testing
@testable import BitMatchEngine

struct CameraLabelSettingsTests {

    @Test
    func testFormattedFolderNameUsesBaseNameWhenLabelIsEmpty() {
        let settings = CameraLabelSettings()
        let folderName = settings.formattedFolderName(for: "A001_C001")
        #expect(folderName == "A001_C001")
    }

    @Test
    func previewFolderNameMatchesCopyForEveryPositionAndSeparator() {
        let source = URL(fileURLWithPath: "/Volumes/A7IV_CARD1", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Volumes/Shuttle", isDirectory: true)

        for position in CameraLabelSettings.LabelPosition.allCases {
            for separator in CameraLabelSettings.Separator.allCases {
                let settings = CameraLabelSettings(
                    label: "A-Cam",
                    position: position,
                    separator: separator
                )
                let preview = SafetyValidator.destinationRootComponents(
                    source: source,
                    settings: settings
                ).joined(separator: "/")
                let copyFolder = SafetyValidator.resolvedDestinationRoot(
                    source: source,
                    destination: destination,
                    settings: settings
                ).path.replacingOccurrences(of: destination.path + "/", with: "")

                #expect(preview == copyFolder)
            }
        }

        let noLabel = CameraLabelSettings(label: "")
        #expect(SafetyValidator.destinationRootComponents(source: source, settings: noLabel) == ["A7IV_CARD1"])
    }
}
