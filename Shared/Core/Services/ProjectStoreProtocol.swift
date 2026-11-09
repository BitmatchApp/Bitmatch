import Foundation

@MainActor
protocol PhotographerJobStore {
    func jobs() throws -> [PhotographerJob]
    func save(_ job: PhotographerJob) throws
    func deleteJob(id: UUID) throws
    func presets() throws -> [PhotographerPreset]
    func save(_ preset: PhotographerPreset) throws
    func addPresetsAtomically(_ presets: [PhotographerPreset]) throws
    func profiles() throws -> [RemoteDestinationProfile]
    func save(_ profile: RemoteDestinationProfile) throws
    func deleteProfile(id: UUID) throws
    func manifests() throws -> [RemoteManifest]
    func save(_ manifest: RemoteManifest) throws
    func deleteManifest(id: UUID) throws
    func queueItems() throws -> [RemoteQueueItem]
    func save(_ item: RemoteQueueItem) throws
    func deleteQueueItem(id: UUID) throws
    var isAvailable: Bool { get }
    func whenAvailable(_ action: @escaping () -> Void)
}

extension PhotographerJobStore {
    func addPresetsAtomically(_: [PhotographerPreset]) throws { throw PortableRecipeImportError.unavailable }
    var isAvailable: Bool { true }
    func whenAvailable(_: @escaping () -> Void) {}
    func profiles() throws -> [RemoteDestinationProfile] { [] }
    func save(_: RemoteDestinationProfile) throws {}
    func deleteProfile(id _: UUID) throws {}
    func manifests() throws -> [RemoteManifest] { [] }
    func save(_: RemoteManifest) throws {}
    func deleteManifest(id _: UUID) throws {}
    func queueItems() throws -> [RemoteQueueItem] { [] }
    func save(_: RemoteQueueItem) throws {}
    func deleteQueueItem(id _: UUID) throws {}
}

enum PortableRecipeImportError: LocalizedError {
    case unavailable, duplicateID

    var errorDescription: String? {
        switch self {
        case .unavailable: "Folder recipes could not be imported into this store."
        case .duplicateID: "A folder recipe changed while importing. Try again."
        }
    }
}
