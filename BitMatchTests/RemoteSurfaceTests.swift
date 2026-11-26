import Foundation
import Testing
@testable import BitMatch

@MainActor
struct RemoteSurfaceTests {
    @Test func theCoordinatorIsARemoteSurface() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteSurfaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "RemoteSurfaceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = SharedAppCoordinator(
            platformManager: MacOSPlatformManager.shared,
            transferJournal: LocalTransferJournal(fileURL: directory.appendingPathComponent("journal.json")),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: defaults
        )
        let surface: any RemoteSurface = coordinator
        #expect(surface.currentMode == .copyAndVerify)
        #expect(surface.destinationURLs.isEmpty)
    }
}
