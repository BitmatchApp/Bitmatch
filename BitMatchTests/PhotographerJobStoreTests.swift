import CoreData
import Foundation
import Testing
@testable import BitMatch

struct PhotographerJobStoreTests {
    @MainActor
    @Test func savedJobRoundTrips() throws {
        let (persistence, store) = makeStore()
        let job = makeJob(id: uuid(101), name: "Smith Wedding", updatedAt: date(200))

        try store.save(job)

        #expect(try store.jobs() == [job])
        _ = persistence
    }

    @Test func legacyJobPayloadDefaultsToPhotographyWorkflow() throws {
        let job = makeJob(id: uuid(100), name: "Legacy", updatedAt: date(200))
        var object = try #require(JSONSerialization.jsonObject(with: encoded(job)) as? [String: Any])
        object.removeValue(forKey: "workflow")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(PhotographerJob.self, from: legacyData).workflow == .photography)
    }

    @MainActor
    @Test func exactVerifiedDestinationCountRoundTrips() throws {
        let (_, store) = makeStore()
        var job = makeJob(id: uuid(106), name: "Three Copies", updatedAt: date(200))
        job.cardIngests = [CardIngest(
            id: uuid(107),
            provenance: CardProvenance(
                photographerID: uuid(108),
                photographerName: "Mike",
                cameraName: "Sony",
                cardNumber: 1,
                preliminaryFingerprint: "preliminary",
                confirmedFingerprint: "confirmed"
            ),
            sourceDisplayName: "CARD1",
            renderedRelativePath: "Card-001",
            localState: .locallySafe,
            startedAt: date(180),
            locallySafeAt: date(190),
            fileCount: 1,
            totalBytes: 100,
            verifiedDestinationCount: 3
        )]

        try store.save(job)

        #expect(try store.jobs().first?.cardIngests.first?.verifiedDestinationCount == 3)
    }

    @MainActor
    @Test func deletingJobRemovesIt() throws {
        let (_, store) = makeStore()
        let job = makeJob(id: uuid(102), name: "Delete Me", updatedAt: date(200))
        try store.save(job)

        try store.deleteJob(id: job.id)

        #expect(try store.jobs().isEmpty)
    }

    @MainActor
    @Test func savingJobWithExistingIDUpdatesRecord() throws {
        let (_, store) = makeStore()
        let original = makeJob(id: uuid(103), name: "Original", updatedAt: date(200))
        var updated = original
        updated.jobName = "Updated"
        updated.updatedAt = date(300)

        try store.save(original)
        try store.save(updated)

        #expect(try store.jobs() == [updated])
    }

    @MainActor
    @Test func jobsAreSortedByUpdatedDateDescending() throws {
        let (_, store) = makeStore()
        let older = makeJob(id: uuid(104), name: "Older", updatedAt: date(200))
        let newer = makeJob(id: uuid(105), name: "Newer", updatedAt: date(300))

        try store.save(older)
        try store.save(newer)

        #expect(try store.jobs() == [newer, older])
    }

    @MainActor
    @Test func weddingPresetRoundTripsWithTwoRequiredLocalCopies() throws {
        let (_, store) = makeStore()
        let preset = makePreset(id: uuid(201), name: "Wedding", requiredLocalCopyCount: 2)

        try store.save(preset)

        let saved = try #require(store.presets().first)
        #expect(saved == preset)
        #expect(saved.requiredLocalCopyCount == 2)
    }

    @MainActor
    @Test func savingPresetWithExistingIDUpdatesRecord() throws {
        let (_, store) = makeStore()
        let original = makePreset(id: uuid(202), name: "Wedding", requiredLocalCopyCount: 2)
        var updated = original
        updated.name = "Updated Wedding"
        updated.requiredLocalCopyCount = 3

        try store.save(original)
        try store.save(updated)

        #expect(try store.presets() == [updated])
    }

    @MainActor
    @Test func importedPresetBatchRollsBackWhenSaveFails() throws {
        let persistence = BitMatchPersistenceController(inMemory: true)
        let credentials = InMemoryRemoteCredentialStore()
        let store = CoreDataPhotographerJobStore(
            context: persistence.container.viewContext,
            credentialStore: credentials.store,
            saveContext: { _ in throw NSError(domain: "PhotographerJobStoreTests", code: 1) }
        )
        let first = makePreset(id: uuid(211), name: "First", requiredLocalCopyCount: 2)
        let second = makePreset(id: uuid(212), name: "Second", requiredLocalCopyCount: 2)

        #expect(throws: (any Error).self) { try store.addPresetsAtomically([first, second]) }
        #expect(try store.presets().isEmpty)
    }

    @MainActor
    @Test func presetsAreSortedByName() throws {
        let (_, store) = makeStore()
        let zulu = makePreset(id: uuid(203), name: "Zulu", requiredLocalCopyCount: 1)
        let alpha = makePreset(id: uuid(204), name: "Alpha", requiredLocalCopyCount: 2)

        try store.save(zulu)
        try store.save(alpha)

        #expect(try store.presets() == [alpha, zulu])
    }

    @MainActor
    @Test func malformedJobPayloadReportsCorruptRecordID() throws {
        let (persistence, store) = makeStore()
        let id = uuid(301)
        let record = NSEntityDescription.insertNewObject(
            forEntityName: "PhotographerJobRecord",
            into: persistence.container.viewContext
        )
        record.setValue(id, forKey: "id")
        record.setValue(date(200), forKey: "updatedAt")
        record.setValue(Data("not-json".utf8), forKey: "payload")
        try persistence.container.viewContext.save()

        #expect(throws: PhotographerStoreError.corruptRecord(id)) {
            try store.jobs()
        }
    }

    @MainActor
    @Test func malformedPresetPayloadReportsCorruptRecordID() throws {
        let (persistence, store) = makeStore()
        let id = uuid(302)
        let record = NSEntityDescription.insertNewObject(
            forEntityName: "PhotographerPresetRecord",
            into: persistence.container.viewContext
        )
        record.setValue(id, forKey: "id")
        record.setValue(date(200), forKey: "updatedAt")
        record.setValue(Data("not-json".utf8), forKey: "payload")
        try persistence.container.viewContext.save()

        #expect(throws: PhotographerStoreError.corruptRecord(id)) {
            try store.presets()
        }
    }

    @MainActor
    @Test func missingRequiredCoreDataAttributesReportCorruptionInsteadOfForceCastCrash() throws {
        let (persistence, store) = makeStore()
        let record = NSEntityDescription.insertNewObject(
            forEntityName: "PhotographerJobRecord",
            into: persistence.container.viewContext
        )
        record.setValue(date(200), forKey: "updatedAt")

        #expect(throws: PhotographerStoreError.corruptRecord(nil)) {
            try store.jobs()
        }
    }

    @MainActor
    @Test func persistentStoreLoadFailureDoesNotCrashAndRepositoryFailsClosed() throws {
        let persistence = BitMatchPersistenceController(
            forcedStoreLoadError: NSError(domain: "StoreLoad", code: 1)
        )
        let store = CoreDataPhotographerJobStore(persistence: persistence)

        #expect(throws: PhotographerStoreError.persistentStoreUnavailable) {
            try store.jobs()
        }
        #expect(throws: PhotographerStoreError.persistentStoreUnavailable) {
            try store.save(makeJob(id: uuid(999), name: "Never Saved", updatedAt: date(200)))
        }
    }

    @MainActor
    @Test func remoteProfileRoundTripsWithoutCredentialInCoreDataPayload() throws {
        let credentials = InMemoryRemoteCredentialStore()
        let (persistence, store) = makeStore(credentials: credentials.store)
        let profile = try makeRemoteProfile(id: uuid(401), name: "Studio SFTP")
        let password = "not-in-core-data"

        try credentials.store.save(RemoteCredential(password: password), for: profile.id)
        try store.save(profile)

        #expect(try store.profiles() == [profile])
        #expect(credentials.data(for: profile.id) != nil)

        let request = NSFetchRequest<NSManagedObject>(entityName: "RemoteDestinationProfileRecord")
        let record = try #require(persistence.container.viewContext.fetch(request).first)
        let payload = try #require(record.value(forKey: "payload") as? Data)
        #expect(!String(decoding: payload, as: UTF8.self).contains(password))
        #expect(record.value(forKey: "credentialAccount") as? String == credentials.store.accountName(for: profile.id))
    }

    @MainActor
    @Test func deletingOneRemoteProfileDeletesOnlyItsKeychainCredential() throws {
        let credentials = InMemoryRemoteCredentialStore()
        let (_, store) = makeStore(credentials: credentials.store)
        let first = try makeRemoteProfile(id: uuid(402), name: "Primary")
        let second = try makeRemoteProfile(id: uuid(403), name: "Archive")

        try store.save(first)
        try store.save(second)
        try credentials.store.save(RemoteCredential(password: "first"), for: first.id)
        try credentials.store.save(RemoteCredential(password: "second"), for: second.id)

        try store.deleteProfile(id: first.id)

        #expect(try store.profiles() == [second])
        #expect(credentials.data(for: first.id) == nil)
        #expect(credentials.data(for: second.id) != nil)
    }

    @MainActor
    @Test func profileDeletionCanBeRetriedWhenKeychainDeletionFails() throws {
        let credentials = InMemoryRemoteCredentialStore()
        let (_, store) = makeStore(credentials: credentials.store)
        let profile = try makeRemoteProfile(id: uuid(404), name: "Retryable")

        try store.save(profile)
        try credentials.store.save(RemoteCredential(password: "credential"), for: profile.id)
        credentials.failNextDeletion()

        #expect(throws: RemoteCredentialStoreError.keychainDeleteFailed) {
            try store.deleteProfile(id: profile.id)
        }
        #expect(try store.profiles().isEmpty)
        #expect(credentials.data(for: profile.id) != nil)

        try store.deleteProfile(id: profile.id)

        #expect(try store.profiles().isEmpty)
        #expect(credentials.data(for: profile.id) == nil)
    }

    @MainActor
    @Test func profileDeletionRemainsHiddenWhenFinalCoreDataSaveFails() throws {
        let credentials = InMemoryRemoteCredentialStore()
        let persistence = BitMatchPersistenceController(inMemory: true)
        var saveCount = 0
        let store = CoreDataPhotographerJobStore(
            context: persistence.container.viewContext,
            credentialStore: credentials.store,
            saveContext: { context in
                saveCount += 1
                if saveCount == 3 {
                    throw NSError(domain: "PhotographerJobStoreTests", code: 1)
                }
                try context.save()
            }
        )
        let profile = try makeRemoteProfile(id: uuid(405), name: "Final Save Failure")

        try store.save(profile)
        try credentials.store.save(RemoteCredential(password: "credential"), for: profile.id)

        var didFail = false
        do {
            try store.deleteProfile(id: profile.id)
        } catch {
            didFail = true
        }

        #expect(didFail)
        #expect(try store.profiles().isEmpty)
        #expect(credentials.data(for: profile.id) == nil)

        let reloadedStore = CoreDataPhotographerJobStore(
            context: persistence.container.viewContext,
            credentialStore: credentials.store,
            saveContext: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try reloadedStore.profiles().isEmpty)
        let request = NSFetchRequest<NSManagedObject>(entityName: "RemoteDestinationProfileRecord")
        #expect(try persistence.container.viewContext.fetch(request).isEmpty)
    }

    @MainActor
    @Test func remoteQueueItemRoundTrips() throws {
        let (_, store) = makeStore()
        let item = try makeRemoteQueueItem(id: uuid(404))

        try store.save(item)

        #expect(try store.queueItems() == [item])
    }

    @MainActor
    @Test func remoteManifestRoundTrips() throws {
        let (_, store) = makeStore()
        let manifest = try makeRemoteManifest(id: uuid(410))

        try store.save(manifest)

        #expect(try store.manifests() == [manifest])
    }

    @MainActor
    @Test func unavailableCoreDataRetriesThroughExistingReadinessCallback() async throws {
        let persistence = BitMatchPersistenceController(inMemory: true, deferStoreLoad: true)
        let store = CoreDataPhotographerJobStore(persistence: persistence)
        var retryCount = 0

        #expect(!store.isAvailable)
        store.whenAvailable {
            retryCount += 1
        }

        persistence.loadPersistentStore()
        while !store.isAvailable {
            await Task.yield()
        }

        #expect(retryCount == 1)
    }

    @MainActor
    @Test func openingPreRemoteBackupStoreMigratesAndLoadsExistingRecords() async throws {
        let storeURL = URL.temporaryDirectory
            .appending(path: "BitMatchMigration-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
        }

        let migratedModel = try #require(legacyModel())
        let legacyContainer = NSPersistentContainer(
            name: "BitMatch",
            managedObjectModel: migratedModel
        )
        let legacyDescription = NSPersistentStoreDescription(url: storeURL)
        legacyContainer.persistentStoreDescriptions = [legacyDescription]
        try await loadPersistentStore(for: legacyContainer)

        let job = makeJob(id: uuid(405), name: "Pre-Remote Store", updatedAt: date(200))
        let record = NSEntityDescription.insertNewObject(
            forEntityName: "PhotographerJobRecord",
            into: legacyContainer.viewContext
        )
        record.setValue(job.id, forKey: "id")
        record.setValue(job.updatedAt, forKey: "updatedAt")
        record.setValue(try encoded(job), forKey: "payload")
        try legacyContainer.viewContext.save()

        let persistence = BitMatchPersistenceController(storeURL: storeURL)
        while !persistence.isStoreLoaded && persistence.persistentStoreLoadError == nil {
            await Task.yield()
        }

        #expect(persistence.persistentStoreLoadError == nil)
        let store = CoreDataPhotographerJobStore(persistence: persistence)
        #expect(try store.jobs() == [job])
    }

    @MainActor
    private func makeStore(
        credentials: RemoteCredentialStore = RemoteCredentialStore()
    ) -> (BitMatchPersistenceController, CoreDataPhotographerJobStore) {
        let persistence = BitMatchPersistenceController(inMemory: true)
        return (
            persistence,
            CoreDataPhotographerJobStore(
                context: persistence.container.viewContext,
                credentialStore: credentials
            )
        )
    }

    private func makeRemoteProfile(id: UUID, name: String) throws -> RemoteDestinationProfile {
        RemoteDestinationProfile(
            id: id,
            name: name,
            host: "sftp.example.com",
            port: 22,
            username: "mike",
            root: try RemoteRelativePath(components: ["Backups", name]),
            verificationMode: .sha256
        )
    }

    private func makeRemoteQueueItem(id: UUID) throws -> RemoteQueueItem {
        let root = try RemoteRelativePath(components: ["Jobs", "Smith"])
        return RemoteQueueItem(
            id: id,
            jobID: uuid(405),
            cardIngestID: uuid(406),
            destinationProfileID: uuid(407),
            manifestID: uuid(408),
            manifestEntryID: uuid(409),
            localArtifactBookmarkReference: "remote-artifact.404",
            localArtifactRelativePath: root,
            remoteRelativePath: try root.appending("Card-001"),
            temporaryRemoteRelativePath: try root.appending(".bitmatch-upload-404"),
            state: .queued,
            uploadedByteCount: 0,
            retryCount: 0,
            nextAttemptAt: nil,
            verificationEvidence: .none,
            errorSummary: nil,
            createdAt: date(200),
            updatedAt: date(200)
        )
    }

    private func makeRemoteManifest(id: UUID) throws -> RemoteManifest {
        try RemoteManifest(
            id: id,
            jobID: uuid(411),
            cardIngestID: uuid(412),
            destinationProfileID: uuid(413),
            packageRelativePath: RemoteRelativePath(components: ["Jobs", "Smith"]),
            entries: [
                RemoteManifestEntry(
                    id: uuid(414),
                    relativePath: RemoteRelativePath(components: ["Card-001", "IMG_0001.ARW"]),
                    byteCount: 1_024,
                    sha256: String(repeating: "a", count: 64)
                )
            ],
            createdAt: date(200)
        )
    }

    private func makeJob(id: UUID, name: String, updatedAt: Date) -> PhotographerJob {
        PhotographerJob(
            id: id,
            eventDate: date(100),
            clientName: "Smith",
            jobName: name,
            eventType: .wedding,
            photographers: [],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: [],
            createdAt: date(150),
            updatedAt: updatedAt
        )
    }

    private func makePreset(
        id: UUID,
        name: String,
        requiredLocalCopyCount: Int
    ) -> PhotographerPreset {
        PhotographerPreset(
            id: id,
            name: name,
            eventType: .wedding,
            recipe: .wedding,
            requiredLocalCopyCount: requiredLocalCopyCount
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func legacyModel() -> NSManagedObjectModel? {
        let bundle = Bundle(for: BitMatchPersistenceController.self)
        guard let url = bundle.url(
            forResource: "BitMatch",
            withExtension: "mom",
            subdirectory: "BitMatch.momd"
        ) else {
            return nil
        }
        return NSManagedObjectModel(contentsOf: url)
    }

    private func loadPersistentStore(for container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

private final class InMemoryRemoteCredentialStore {
    private var dataByAccount: [String: Data] = [:]
    private var shouldFailNextDeletion = false

    lazy var store = RemoteCredentialStore(
        saveData: { [weak self] data, account in
            self?.dataByAccount[account] = data
            return self != nil
        },
        loadData: { [weak self] account in
            self?.dataByAccount[account]
        },
        deleteData: { [weak self] account in
            guard let self else { return false }
            if self.shouldFailNextDeletion {
                self.shouldFailNextDeletion = false
                return false
            }
            self.dataByAccount.removeValue(forKey: account)
            return true
        }
    )

    func failNextDeletion() {
        shouldFailNextDeletion = true
    }

    func data(for profileID: UUID) -> Data? {
        dataByAccount[store.accountName(for: profileID)]
    }
}
