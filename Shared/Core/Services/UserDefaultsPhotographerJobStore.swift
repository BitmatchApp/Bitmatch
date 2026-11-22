import Foundation

/// Portable persistence for the iOS project workflow. It intentionally stores
/// only Codable project metadata; credentials remain outside BitMatch.
@MainActor
final class UserDefaultsPhotographerJobStore: PhotographerJobStore {
    private enum Key {
        static let jobs = "photographerJobs"
        static let presets = "photographerPresets"
        static let profiles = "remoteDestinationProfiles"
        static let manifests = "remoteManifests"
        static let queueItems = "remoteQueueItems"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func jobs() throws -> [PhotographerJob] { try read([PhotographerJob].self, key: Key.jobs) }
    func presets() throws -> [PhotographerPreset] { try read([PhotographerPreset].self, key: Key.presets) }
    func profiles() throws -> [RemoteDestinationProfile] { try read([RemoteDestinationProfile].self, key: Key.profiles) }
    func manifests() throws -> [RemoteManifest] { try read([RemoteManifest].self, key: Key.manifests) }
    func queueItems() throws -> [RemoteQueueItem] { try read([RemoteQueueItem].self, key: Key.queueItems) }

    func save(_ job: PhotographerJob) throws { try upsert(job, key: Key.jobs, values: jobs()) }
    func save(_ preset: PhotographerPreset) throws { try upsert(preset, key: Key.presets, values: presets()) }

    func addPresetsAtomically(_ additions: [PhotographerPreset]) throws {
        let existing = try presets()
        let ids = existing.map(\.id) + additions.map(\.id)
        guard Set(ids).count == ids.count else { throw PortableRecipeImportError.duplicateID }
        try write(existing + additions, key: Key.presets)
    }
    func save(_ profile: RemoteDestinationProfile) throws { try upsert(profile, key: Key.profiles, values: profiles()) }
    func save(_ manifest: RemoteManifest) throws { try upsert(manifest, key: Key.manifests, values: manifests()) }
    func save(_ item: RemoteQueueItem) throws { try upsert(item, key: Key.queueItems, values: queueItems()) }

    func deleteJob(id: UUID) throws { try delete(id: id, key: Key.jobs, values: jobs()) }
    func deleteProfile(id: UUID) throws { try delete(id: id, key: Key.profiles, values: profiles()) }
    func deleteManifest(id: UUID) throws { try delete(id: id, key: Key.manifests, values: manifests()) }
    func deleteQueueItem(id: UUID) throws { try delete(id: id, key: Key.queueItems, values: queueItems()) }

    private func read<Value: Codable>(_ type: [Value].Type, key: String) throws -> [Value] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try decoder.decode(type, from: data)
    }

    private func upsert<Value: Codable & Identifiable>(_ value: Value, key: String, values: [Value]) throws where Value.ID == UUID {
        var updated = values
        if let index = updated.firstIndex(where: { $0.id == value.id }) {
            updated[index] = value
        } else {
            updated.append(value)
        }
        try write(updated, key: key)
    }

    private func delete<Value: Codable & Identifiable>(id: UUID, key: String, values: [Value]) throws where Value.ID == UUID {
        try write(values.filter { $0.id != id }, key: key)
    }

    private func write<Value: Codable>(_ value: Value, key: String) throws {
        defaults.set(try encoder.encode(value), forKey: key)
    }
}
