import Foundation
import BitMatchEngine

/// A presentation-level workflow choice. The existing photographer data
/// model remains the persistence substrate while projects gain a broader
/// product identity.
/// Case order is the picker order: Video / DIT first (most offloads).
enum ProjectWorkflow: String, Codable, CaseIterable, Sendable {
    case videoDIT
    case photography
    case general

    var title: String {
        switch self {
        case .photography: "Photography"
        case .videoDIT: "Video / DIT"
        case .general: "General media"
        }
    }

    var contributorLabel: String {
        switch self {
        case .photography: "Photographer"
        case .videoDIT: "Operator"
        case .general: "Contributor"
        }
    }

    /// Placeholders that read as examples, never as filled-in values.
    var fieldExamples: (client: String, job: String, contributor: String, camera: String) {
        switch self {
        case .videoDIT: ("e.g. Northlight Films", "e.g. Day 3", "e.g. A-cam DIT", "e.g. Sony FX6")
        case .photography: ("e.g. Smith", "e.g. Smith Wedding", "e.g. Alex", "e.g. Sony A7 IV")
        case .general: ("e.g. Acme", "e.g. Spring Campaign", "e.g. Alex", "e.g. GoPro")
        }
    }

    var sourceUnitLabel: String {
        switch self {
        case .photography: "Card"
        case .videoDIT: "Media"
        case .general: "Package"
        }
    }
}

enum PhotographerEventType: String, Codable, CaseIterable, Sendable {
    case wedding = "Wedding"
    case event = "Event"
    case portrait = "Portrait"
    case commercial = "Commercial"
}

enum FolderLayerKind: String, Codable, CaseIterable, Sendable {
    case dateAndJob
    case originals
    case photographer
    case camera
    case cardNumber
}

struct FolderLayer: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: FolderLayerKind
    var isEnabled: Bool
}

struct FolderRecipe: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var layers: [FolderLayer]

    static let wedding = FolderRecipe(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Wedding",
        layers: FolderLayerKind.allCases.map {
            FolderLayer(id: UUID(), kind: $0, isEnabled: true)
        }
    )

    static let videoDIT = FolderRecipe(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Video / DIT",
        layers: [
            .dateAndJob, .originals, .camera, .cardNumber
        ].map { FolderLayer(id: UUID(), kind: $0, isEnabled: true) }
    )

    static let generalMedia = FolderRecipe(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "General media",
        layers: [
            .dateAndJob, .originals, .cardNumber
        ].map { FolderLayer(id: UUID(), kind: $0, isEnabled: true) }
    )

    static let builtInRecipes = [wedding, videoDIT, generalMedia]

    static func builtInRecipe(id: UUID) -> FolderRecipe? {
        builtInRecipes.first { $0.id == id }
    }
}

extension ProjectWorkflow {
    var defaultRecipe: FolderRecipe {
        switch self {
        case .photography: .wedding
        case .videoDIT: .videoDIT
        case .general: .generalMedia
        }
    }
}

struct FolderRecipeContext: Codable, Equatable, Sendable {
    let eventDate: Date
    let jobName: String
    let photographer: String
    let camera: String
    let cardNumber: Int
}

struct RenderedFolderRecipe: Codable, Equatable, Sendable {
    let components: [String]
    var relativePath: String { components.joined(separator: "/") }
}

enum FolderRecipeError: LocalizedError, Codable, Equatable, Sendable {
    case missingRequiredValue(String)
    case invalidCardNumber

    var errorDescription: String? {
        switch self {
        case .missingRequiredValue(let label): return "Enter a value for \(label)."
        case .invalidCardNumber: return "Card number must be greater than zero."
        }
    }
}

enum PhotographerLocalState: String, Codable, Sendable {
    case notStarted, copying, verifying, locallySafe, issues, cancelled
}

struct PhotographerIdentity: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
}

struct CardProvenance: Codable, Equatable, Sendable {
    var photographerID: UUID
    var photographerName: String
    var cameraName: String
    var cardNumber: Int
    var preliminaryFingerprint: String?
    var confirmedFingerprint: String?
}

struct CardIngest: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var provenance: CardProvenance
    var sourceDisplayName: String
    var renderedRelativePath: String
    var localState: PhotographerLocalState
    var startedAt: Date?
    var locallySafeAt: Date?
    var fileCount: Int
    var totalBytes: Int64
    var verifiedDestinationCount: Int
    var remoteBackupSummaries: [UUID: RemoteBackupCardSummary]

    init(
        id: UUID,
        provenance: CardProvenance,
        sourceDisplayName: String,
        renderedRelativePath: String,
        localState: PhotographerLocalState,
        startedAt: Date?,
        locallySafeAt: Date?,
        fileCount: Int,
        totalBytes: Int64,
        verifiedDestinationCount: Int = 0,
        remoteBackupSummaries: [UUID: RemoteBackupCardSummary] = [:]
    ) {
        self.id = id
        self.provenance = provenance
        self.sourceDisplayName = sourceDisplayName
        self.renderedRelativePath = renderedRelativePath
        self.localState = localState
        self.startedAt = startedAt
        self.locallySafeAt = locallySafeAt
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.verifiedDestinationCount = verifiedDestinationCount
        self.remoteBackupSummaries = remoteBackupSummaries
    }

    private enum CodingKeys: String, CodingKey {
        case id, provenance, sourceDisplayName, renderedRelativePath, localState
        case startedAt, locallySafeAt, fileCount, totalBytes, verifiedDestinationCount, remoteBackupSummaries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        provenance = try values.decode(CardProvenance.self, forKey: .provenance)
        sourceDisplayName = try values.decode(String.self, forKey: .sourceDisplayName)
        renderedRelativePath = try values.decode(String.self, forKey: .renderedRelativePath)
        localState = try values.decode(PhotographerLocalState.self, forKey: .localState)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        locallySafeAt = try values.decodeIfPresent(Date.self, forKey: .locallySafeAt)
        fileCount = try values.decode(Int.self, forKey: .fileCount)
        totalBytes = try values.decode(Int64.self, forKey: .totalBytes)
        verifiedDestinationCount = try values.decodeIfPresent(Int.self, forKey: .verifiedDestinationCount) ?? 0
        remoteBackupSummaries = try values.decodeIfPresent([UUID: RemoteBackupCardSummary].self, forKey: .remoteBackupSummaries) ?? [:]
    }
}

struct PhotographerSetupSignature: Codable, Equatable, Sendable {
    let clientName: String
    let jobName: String
    let eventDate: Date
    let photographerName: String
    let cameraName: String
    let cardNumber: Int
    let recipe: FolderRecipe
}

struct PhotographerJob: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var eventDate: Date
    var clientName: String
    var jobName: String
    var eventType: PhotographerEventType
    var photographers: [PhotographerIdentity]
    var recipe: FolderRecipe
    var requiredLocalCopyCount: Int
    var cardIngests: [CardIngest]
    var remoteBackupConfiguration: RemoteBackupConfiguration? = nil
    var workflow: ProjectWorkflow = .photography
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        eventDate: Date,
        clientName: String,
        jobName: String,
        eventType: PhotographerEventType,
        photographers: [PhotographerIdentity],
        recipe: FolderRecipe,
        requiredLocalCopyCount: Int,
        cardIngests: [CardIngest],
        remoteBackupConfiguration: RemoteBackupConfiguration? = nil,
        workflow: ProjectWorkflow = .photography,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.eventDate = eventDate
        self.clientName = clientName
        self.jobName = jobName
        self.eventType = eventType
        self.photographers = photographers
        self.recipe = recipe
        self.requiredLocalCopyCount = requiredLocalCopyCount
        self.cardIngests = cardIngests
        self.remoteBackupConfiguration = remoteBackupConfiguration
        self.workflow = workflow
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventDate, clientName, jobName, eventType, photographers, recipe
        case requiredLocalCopyCount, cardIngests, remoteBackupConfiguration, workflow, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        eventDate = try values.decode(Date.self, forKey: .eventDate)
        clientName = try values.decode(String.self, forKey: .clientName)
        jobName = try values.decode(String.self, forKey: .jobName)
        eventType = try values.decode(PhotographerEventType.self, forKey: .eventType)
        photographers = try values.decode([PhotographerIdentity].self, forKey: .photographers)
        recipe = try values.decode(FolderRecipe.self, forKey: .recipe)
        requiredLocalCopyCount = try values.decode(Int.self, forKey: .requiredLocalCopyCount)
        cardIngests = try values.decode([CardIngest].self, forKey: .cardIngests)
        remoteBackupConfiguration = try values.decodeIfPresent(RemoteBackupConfiguration.self, forKey: .remoteBackupConfiguration)
        workflow = try values.decodeIfPresent(ProjectWorkflow.self, forKey: .workflow) ?? .photography
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

struct PhotographerPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var eventType: PhotographerEventType
    var recipe: FolderRecipe
    var requiredLocalCopyCount: Int
    var workflow: ProjectWorkflow = .photography
}

struct PhotographerReportContext: Codable, Equatable, Sendable {
    let job: PhotographerJob
    let cardIngestID: UUID
    let analysis: CardAnalysis
    let verifiedDestinationCount: Int
    let warnings: [String]
    /// Caps verified destinations when several folders share one physical
    /// drive. Nil preserves records and call sites from older versions.
    var independentDestinationCount: Int? = nil
}

enum PhotographerReportError: Error, Equatable {
    case cardNotFound
    case cardNotReady
}

struct PhotographerReportPayload: Codable, Equatable, Sendable {
    struct RemoteBackupEvidence: Codable, Equatable, Sendable, Identifiable {
        let targetID: UUID
        let status: String
        let remotePath: String?
        let verificationEvidence: RemoteVerificationEvidence
        let errorSummary: String?
        let updatedAt: Date?

        var id: UUID { targetID }
    }
    struct CompanionCounts: Codable, Equatable, Sendable {
        let raw: Int
        let jpeg: Int
        let sidecar: Int
    }

    struct Result: Codable, Equatable, Sendable {
        let id: UUID
        let path: String
        let status: String
        let size: Int64
        let checksum: String?
        let destination: String?
        let destinationPath: String?
        let successful: Bool

        init(_ row: ResultRow) {
            id = row.id
            path = row.path
            status = row.status
            size = row.size
            checksum = row.checksum
            destination = row.destination
            destinationPath = row.destinationPath
            successful = row.isSuccessStatus
        }
    }

    struct FinalizedCard: Equatable {
        let card: CardIngest
        let verifiedDestinationCount: Int
    }

    private struct FinalEvidence {
        let destinationCount: Int
        let canonicalRows: [ResultRow]
    }

    let jobID: UUID
    let jobName: String
    let clientName: String
    let eventDate: Date
    let eventType: PhotographerEventType
    let card: CardIngest
    let analysis: CardAnalysis
    let companionCounts: CompanionCounts
    let requiredLocalCopyCount: Int
    let verifiedDestinationCount: Int
    let locallySafeAt: Date?
    let fullyBackedUpAt: Date?
    let remoteBackupEvidence: [RemoteBackupEvidence]
    let warnings: [String]
    let results: [Result]

    var isLocallySafe: Bool {
        card.localState == .locallySafe
            && locallySafeAt != nil
            && card.locallySafeAt != nil
            && !(card.provenance.confirmedFingerprint ?? "").isEmpty
            && requiredLocalCopyCount > 0
            && verifiedDestinationCount >= requiredLocalCopyCount
            && card.verifiedDestinationCount == verifiedDestinationCount
    }

    static func make(
        context: PhotographerReportContext,
        results: [ResultRow]
    ) throws -> PhotographerReportPayload {
        try make(context: context, results: results, finishedAt: nil)
    }

    static func make(
        context: PhotographerReportContext,
        results: [ResultRow],
        finishedAt _: Date?
    ) throws -> PhotographerReportPayload {
        let finalized = try reportFinalizedCard(
            context: context,
            results: results
        )
        let card = finalized.card

        let groups = context.analysis.companionGroups
        return PhotographerReportPayload(
            jobID: context.job.id,
            jobName: context.job.jobName,
            clientName: context.job.clientName,
            eventDate: context.job.eventDate,
            eventType: context.job.eventType,
            card: card,
            analysis: context.analysis,
            companionCounts: CompanionCounts(
                raw: groups.reduce(0) { $0 + $1.rawPaths.count },
                jpeg: groups.reduce(0) { $0 + $1.jpegPaths.count },
                sidecar: groups.reduce(0) { $0 + $1.sidecarPaths.count }
            ),
            requiredLocalCopyCount: context.job.requiredLocalCopyCount,
            verifiedDestinationCount: finalized.verifiedDestinationCount,
            locallySafeAt: card.locallySafeAt,
            fullyBackedUpAt: fullyBackedUpAt(for: card),
            remoteBackupEvidence: remoteEvidence(for: card),
            warnings: context.warnings,
            results: results.map(Result.init)
        )
    }

    private static func fullyBackedUpAt(for card: CardIngest) -> Date? {
        card.remoteBackupSummaries.values
            .filter { RemoteBackupStatusPresentation.make(summary: $0).isFullyBackedUp }
            .compactMap(\.updatedAt)
            .max()
    }

    private static func remoteEvidence(for card: CardIngest) -> [RemoteBackupEvidence] {
        card.remoteBackupSummaries.values.map { summary in
            RemoteBackupEvidence(
                targetID: summary.targetID,
                status: RemoteBackupStatusPresentation.make(summary: summary).title,
                remotePath: summary.remotePath?.description,
                verificationEvidence: summary.verificationEvidence,
                errorSummary: summary.errorSummary,
                updatedAt: summary.updatedAt
            )
        }.sorted { $0.targetID.uuidString < $1.targetID.uuidString }
    }

    static func finalizedCard(
        context: PhotographerReportContext,
        results: [ResultRow],
        finishedAt: Date?
    ) throws -> FinalizedCard {
        return try finalizedCard(
            context: context,
            results: results,
            finishedAt: finishedAt,
            confirmedFingerprint: PhotographerCardAnalyzer.confirmedFingerprint
        )
    }

    static func finalizedCard(
        context: PhotographerReportContext,
        results: [ResultRow],
        finishedAt: Date?,
        confirmedFingerprint: ([ResultRow]) throws -> String
    ) throws -> FinalizedCard {
        guard var card = context.job.cardIngests.first(where: { $0.id == context.cardIngestID }) else {
            throw PhotographerReportError.cardNotFound
        }

        if let evidence = finalEvidence(context: context, card: card, results: results) {
            card.localState = .locallySafe
            card.locallySafeAt = card.locallySafeAt ?? finishedAt ?? context.job.updatedAt
            card.provenance.confirmedFingerprint = try confirmedFingerprint(evidence.canonicalRows)
            card.verifiedDestinationCount = evidence.destinationCount
            return FinalizedCard(
                card: card,
                verifiedDestinationCount: evidence.destinationCount
            )
        }

        return unsafeFinalizedCard(card)
    }

    static func reportFinalizedCard(
        context: PhotographerReportContext,
        results: [ResultRow]
    ) throws -> FinalizedCard {
        guard let card = context.job.cardIngests.first(where: { $0.id == context.cardIngestID }) else {
            throw PhotographerReportError.cardNotFound
        }
        let evidence = finalEvidence(context: context, card: card, results: results)
        guard card.localState == .locallySafe,
              card.locallySafeAt != nil,
              let fingerprint = nonblank(card.provenance.confirmedFingerprint),
              let evidence,
              card.verifiedDestinationCount == evidence.destinationCount,
              (try? PhotographerCardAnalyzer.confirmedFingerprint(results: evidence.canonicalRows)) == fingerprint else {
            return unsafeFinalizedCard(card)
        }
        return FinalizedCard(
            card: card,
            verifiedDestinationCount: evidence.destinationCount
        )
    }

    private static func unsafeFinalizedCard(_ card: CardIngest) -> FinalizedCard {
        var card = card
        card.localState = .issues
        card.locallySafeAt = nil
        card.provenance.confirmedFingerprint = nil
        card.verifiedDestinationCount = 0
        return FinalizedCard(card: card, verifiedDestinationCount: 0)
    }

    private static func finalEvidence(
        context: PhotographerReportContext,
        card: CardIngest,
        results: [ResultRow]
    ) -> FinalEvidence? {
        let expectedPaths = context.analysis.sourcePaths
        let expectedSet = Set(expectedPaths)
        let identifiedRows = results.compactMap { row -> (String, ResultRow)? in
            guard let identity = destinationIdentity(for: row, packagePath: card.renderedRelativePath) else {
                return nil
            }
            return (identity, row)
        }
        let groups = Dictionary(grouping: identifiedRows, by: \.0).mapValues { $0.map(\.1) }
        let manifests = groups.mapValues { rows in
            rows.reduce(into: [String: String]()) { manifest, row in
                manifest[row.path] = row.checksum ?? ""
            }
        }
        let independentCount = min(
            groups.count,
            max(0, context.independentDestinationCount ?? groups.count)
        )
        let hasExactEvidence = !expectedPaths.isEmpty
            && expectedSet.count == expectedPaths.count
            && expectedPaths.count == card.fileCount
            && identifiedRows.count == results.count
            && independentCount >= context.job.requiredLocalCopyCount
            && groups.values.allSatisfy { rows in
                rows.count == expectedPaths.count
                    && Set(rows.map(\.path)) == expectedSet
                    && rows.allSatisfy(isVerified)
            }
        let checksumsAgree = expectedPaths.allSatisfy { path in
            let checksums = Set(manifests.values.compactMap { $0[path] })
            return checksums.count == 1 && checksums.first?.isEmpty == false
        }
        guard hasExactEvidence, checksumsAgree,
              let canonicalRows = groups.sorted(by: { $0.key < $1.key }).first?.value.sorted(by: { $0.path < $1.path }) else {
            return nil
        }
        return FinalEvidence(destinationCount: independentCount, canonicalRows: canonicalRows)
    }

    private static func destinationIdentity(for row: ResultRow, packagePath: String) -> String? {
        guard let destinationPath = nonblank(row.destinationPath),
              destinationPath.hasPrefix("/"),
              let packageComponents = normalizedRelativePathComponents(packagePath) else {
            return nil
        }
        let pathComponents = URL(fileURLWithPath: destinationPath).standardizedFileURL.pathComponents
        guard let packageStart = pathComponents.firstSubsequenceIndex(of: packageComponents) else {
            return nil
        }
        let packageEnd = packageStart + packageComponents.count
        guard packageEnd < pathComponents.count else {
            return nil
        }
        return NSString.path(withComponents: Array(pathComponents[..<packageEnd]))
    }

    private static func normalizedRelativePathComponents(_ path: String) -> [String]? {
        guard !path.hasPrefix("/") else { return nil }
        var components: [String] = []
        for rawComponent in path.split(separator: "/", omittingEmptySubsequences: false) {
            switch rawComponent {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(rawComponent))
            }
        }
        return components.isEmpty ? nil : components
    }

    private static func isVerified(_ row: ResultRow) -> Bool {
        row.isSuccessStatus
            && nonblank(row.path) != nil
            && nonblank(row.checksum) != nil
            && nonblank(row.destinationPath) != nil
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension Array where Element: Equatable {
    func firstSubsequenceIndex(of subsequence: [Element]) -> Int? {
        guard !subsequence.isEmpty, subsequence.count <= count else { return nil }
        for start in 0...(count - subsequence.count) {
            if Array(self[start..<(start + subsequence.count)]) == subsequence {
                return start
            }
        }
        return nil
    }
}
