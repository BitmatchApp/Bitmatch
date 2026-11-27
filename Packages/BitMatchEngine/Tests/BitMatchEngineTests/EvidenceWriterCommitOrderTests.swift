import Foundation
import Darwin
import CryptoKit
import Synchronization
import Testing
@testable import BitMatchEngine

struct EvidenceWriterCommitOrderTests {
    @Test func pinnedReportRefusesSameInodeRewriteWithRestoredMtime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("report.pdf")
        try Data("ours".utf8).write(to: path)
        var original = stat()
        #expect(lstat(path.path, &original) == 0)
        let pinned = try PinnedReportFile(url: path)
        try Data("evil".utf8).write(to: path)
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, path.path, &times, 0) == 0)
        var rewritten = stat()
        #expect(lstat(path.path, &rewritten) == 0)
        #expect(rewritten.st_ino == original.st_ino)
        #expect(rewritten.st_size == original.st_size)
        #expect(rewritten.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
        #expect(rewritten.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
        #expect(throws: PinnedReportFile.IdentityChanged.self) { try pinned.remove() }
        #expect(try Data(contentsOf: path) == Data("evil".utf8))
    }

    @Test func pinnedReportClosesDescriptorsBeforeRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("report.pdf")
        try Data("ours".utf8).write(to: path)
        var descriptors: [Int32] = []
        let pinned = try PinnedReportFile(url: path, didOpen: { descriptors.append($0) })
        try pinned.rename(to: root.appendingPathComponent("hidden"), beforeAction: {
            #expect(!descriptors.isEmpty)
            #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) == -1 && errno == EBADF })
        })
    }

    @Test func pinnedReportRefusesReplacementAfterDigest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("report.pdf")
        try Data("ours".utf8).write(to: path)
        let pinned = try PinnedReportFile(url: path)
        try Data("foreign".utf8).write(to: path, options: .atomic)
        #expect(throws: (any Error).self) { try pinned.requireUnchanged() }
        #expect(try Data(contentsOf: path) == Data("foreign".utf8))
    }

    @Test(arguments: [false, true])
    func rollbackPinsPublishedOccupantAndReportsUnreadable(readFailure: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let published = Mutex<URL?>(nil)
        let foreign = Data("foreign occupant".utf8)
        do {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("ours".utf8), results: [], finished: Date(), checksumAlgorithm: nil,
                jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforePublish: { url in
                    if url.pathExtension == "pdf" { published.withLock { $0 = url } }
                    if url.pathExtension == "json" {
                        if readFailure, let pdf = published.withLock({ $0 }) {
                            try FileManager.default.removeItem(at: pdf)
                            try FileManager.default.createDirectory(at: pdf, withIntermediateDirectories: false)
                        }
                        throw DeliberateFailure.encode
                    }
                }, beforeRollbackRemoval: { url in
                    if !readFailure && url.pathExtension == "pdf" { try foreign.write(to: url, options: .atomic) }
                })
            Issue.record("Publication must fail")
        } catch let error as ReportExportError {
            let pdf = try #require(published.withLock { $0 })
            #expect(error.pendingWithdrawalPaths.contains(pdf.path))
            if readFailure {
                #expect(error.localizedDescription.contains("could not be verified and was left in place"))
            } else {
                #expect(error.localizedDescription.contains("changed during publication and was left in place"))
                #expect(try Data(contentsOf: pdf) == foreign)
            }
        }
    }

    @Test func verifiedReportActionFailuresHaveAccurateReasons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("report.pdf")
        try Data("ours".utf8).write(to: path)
        let pinned = try PinnedReportFile(url: path)
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        do {
            try pinned.remove(beforeAction: { throw denied })
            Issue.record("Removal should fail")
        } catch {
            #expect(error.localizedDescription.contains("could not be removed"))
        }
        do {
            try pinned.replace(with: root.appendingPathComponent("replacement"), beforeAction: { throw denied })
            Issue.record("Replacement should fail")
        } catch {
            #expect(error.localizedDescription.contains("could not be replaced"))
        }
        #expect(try Data(contentsOf: path) == Data("ours".utf8))
    }

    @Test func publicationReportsVerifiedRemoveAndReplaceFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), date = Date()
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        do {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root], pdfData: Data("new".utf8),
                results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                sourceURL: nil, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforePublish: { if $0.pathExtension == "json" { throw DeliberateFailure.encode } },
                beforeRollbackUnlinkAction: { _ in throw denied })
            Issue.record("Rollback should fail")
        } catch let error as ReportExportError {
            #expect(error.localizedDescription.contains("could not be removed"))
            #expect(!error.pendingWithdrawalPaths.isEmpty)
        }
        let otherRoot = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [otherRoot], pdfData: Data("old".utf8),
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: nil, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        do {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [otherRoot], pdfData: Data("replacement".utf8),
                results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                sourceURL: nil, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: false, replacing: original, beforeReplacementAction: { _ in throw denied })
            Issue.record("Replacement should fail")
        } catch {
            #expect(error.localizedDescription.contains("could not be replaced"))
        }
    }

    @Test func rollbackReadFailureAfterHashIsNotReportedAsChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root], pdfData: Data("ours".utf8), results: [], finished: Date(), checksumAlgorithm: nil, jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true, beforePublish: { url in
                if url.pathExtension == "json" { throw DeliberateFailure.encode }
            }, beforeRollbackRemoval: { url in
                if url.pathExtension == "pdf" { try FileManager.default.removeItem(at: url) }
            })
            Issue.record("Publication must fail")
        } catch let error as ReportExportError {
            #expect(error.localizedDescription.contains("could not be verified"))
            #expect(!error.localizedDescription.contains("changed during publication"))
        }
    }

    private func recordFixtureFacts(_ journal: TransferJournal, id: UUID, files: [URL]) throws {
        let facts = try files.map { url in
            let data = try Data(contentsOf: url)
            return ReportFileFact(path: url.path, size: UInt64(data.count), modificationDate: nil,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        try journal.recordIntendedReportFacts(id: id, facts: facts, publicationID: id)
        try journal.promoteIntendedReportFacts(id: id, paths: files.map(\.path))
    }

    @Test func replacementRefusesSwapDuringOwnershipValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil, results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try recordFixtureFacts(journal, id: id, files: files)
        let snapshot = try #require(journal.records.first)
        let csv = try #require(files.first { $0.pathExtension == "csv" })
        let visits = Mutex(0)
        await #expect(throws: ReportReplacementOwnershipError.self) {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil, results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false, replacing: files, validateReplacement: { url in
                try TransferJournal.validateReportReplacement(record: snapshot, paths: files.map(\.path), target: url.path)
                if url == csv && visits.withLock({ $0 += 1; return $0 }) == 2 {
                    try Data("foreign".utf8).write(to: url, options: .atomic)
                }
            })
        }
        #expect(try Data(contentsOf: csv) == Data("foreign".utf8))
    }

    @Test func successfulExportClearsRecordedStagingPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil,
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
            safeToErase: false, recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0, publicationID: id) })
        try recordFixtureFacts(journal, id: id, files: files)
        let record = try #require(journal.records.first)
        #expect(record.reportStagingPath == nil)
        #expect(Set(record.pendingReportPaths ?? []).isSuperset(of: Set(files.map(\.path))))
    }
    @Test func publishedSiblingDigestProtectsReplacementAndWithdrawal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8), results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try recordFixtureFacts(journal, id: id, files: files)
        let record = try #require(journal.records.first)
        let pdf = try #require(files.first { $0.pathExtension == "pdf" })
        let fact = try #require(record.reportFileFacts?.first(where: { $0.path == pdf.path }))
        let digest = try #require(fact.sha256)
        try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: pdf.path)
        var changedTimestamp = record
        changedTimestamp.reportFileFacts = [ReportFileFact(path: pdf.path, size: fact.size,
            modificationDate: .distantPast, sha256: digest)]
        try TransferJournal.validateReportReplacement(record: changedTimestamp, paths: files.map(\.path), target: pdf.path)
        try Data("evil".utf8).write(to: pdf, options: .atomic) // Same size, different digest.
        #expect(throws: ReportReplacementOwnershipError.self) {
            try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: pdf.path)
        }
        let outcomes = TransferJournal.withdrawReports(record: record, paths: files.map(\.path))
        guard case .pending(let reason) = outcomes[pdf.path] else { Issue.record("Changed file must remain in place"); return }
        #expect(reason.contains("left in place"))
        #expect(try Data(contentsOf: pdf) == Data("evil".utf8))
    }

    @Test func changedJSONIsNotWithdrawnOrReplaced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8), results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try recordFixtureFacts(journal, id: id, files: files)
        let record = try #require(journal.records.first)
        let json = try #require(files.first { $0.pathExtension == "json" })
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        object["foreign"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: json)
        #expect(throws: ReportReplacementOwnershipError.self) {
            try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: json.path)
        }
        let outcomes = TransferJournal.withdrawReports(record: record, paths: files.map(\.path))
        guard case .pending = outcomes[json.path] else { Issue.record("Changed JSON must remain"); return }
        #expect(FileManager.default.fileExists(atPath: json.path))
    }

    @Test func foreignSiblingDoesNotKeepOwnedJSONPublic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8), results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try recordFixtureFacts(journal, id: id, files: files)
        let record = try #require(journal.records.first)
        let pdf = try #require(files.first { $0.pathExtension == "pdf" })
        let json = try #require(files.first { $0.pathExtension == "json" })
        try Data("evil".utf8).write(to: pdf)
        let outcomes = TransferJournal.withdrawReports(record: record, paths: files.map(\.path))
        #expect(outcomes[json.path] == .withdrawn)
        #expect(try Data(contentsOf: pdf) == Data("evil".utf8))
    }

    @Test func intendedFactsSurviveFailedPostPublicationWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let old = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("old".utf8), results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        try recordFixtureFacts(journal, id: id, files: old)
        let snapshot = try #require(journal.records.first)
        let readsOnMain = Mutex(false)
        let files = try await Task.detached {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8), results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true, replacing: old,
                recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0, publicationID: id) },
                recordIntendedFacts: { facts in
                    try journal.recordIntendedReportFacts(id: id, facts: facts, publicationID: id)
                }, beforeStagedReportRead: { _ in readsOnMain.withLock { $0 = $0 || Thread.isMainThread } },
                validateReplacement: { try TransferJournal.validateReportReplacement(record: snapshot, paths: old.map(\.path), target: $0.path) })
        }.value
        #expect(!readsOnMain.withLock { $0 })
        // Simulate a failed journal write after all replacement renames.
        let record = try #require(journal.records.first)
        let firstGeneration = try #require(record.intendedReportFileFacts)
        #expect(firstGeneration.count == files.count)
        // A recovery export may itself be interrupted before its first rename.
        // Its intended facts must not discard the safe bytes already published.
        let nextGeneration = firstGeneration.map {
            ReportFileFact(path: $0.path, size: $0.size, modificationDate: nil, sha256: String(repeating: "0", count: 64))
        }
        try journal.recordIntendedReportFacts(id: id, facts: nextGeneration, publicationID: id)
        let duringRecovery = try #require(journal.records.first)
        let outcomes = TransferJournal.withdrawReports(record: duringRecovery, paths: files.map(\.path))
        #expect(files.allSatisfy { outcomes[$0.path] == .withdrawn })
    }

    @Test func failedRestoreTracksStagingCopiesForWithdrawal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8),
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        var stagingPaths: [String] = []
        do {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("warning".utf8),
                results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: false, replacing: files,
                beforePublish: { if $0.pathExtension == "json" { throw DeliberateFailure.encode } },
                beforeRestore: { _ in throw DeliberateFailure.encode })
            Issue.record("Expected failed restoration")
        } catch let error as ReportExportError {
            stagingPaths = error.pendingWithdrawalPaths
            #expect(!stagingPaths.isEmpty)
            #expect(!error.localizedDescription.contains("Original reports retained"))
        }
        try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: "Reports unsettled",
            pendingWithdrawalPaths: files.map(\.path) + stagingPaths)
        try journal.retryPendingReportWithdrawals(id: id)
        #expect(journal.records.first?.pendingWithdrawalPaths == nil)
        #expect(stagingPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func replacementOwnershipRejectsForeignOccupant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8),
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        let pdf = try #require(files.first { $0.pathExtension == "pdf" })
        let record = try #require(journal.records.first)
        await #expect(throws: ReportReplacementOwnershipError.self) {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("new".utf8),
                results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: false, replacing: files,
                validateReplacement: { url in
                    try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: url.path)
                }, beforePublish: { url in
                    if url == pdf {
                        let json = try #require(files.first { $0.pathExtension == "json" })
                        try Data("foreign occupant".utf8).write(to: json, options: .atomic)
                    }
                })
        }
        #expect(try Data(contentsOf: pdf) == Data("safe".utf8))
    }

    @Test func legacyReplacementRequiresMatchingAvailableFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil,
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        let json = try #require(files.first { $0.pathExtension == "json" })
        let csv = try #require(files.first { $0.pathExtension == "csv" })
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString]).write(to: json)
        var record = try #require(journal.records.first)
        record.runSourceURL = nil
        record.reportFileFacts = nil
        try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: csv.path)
        record.reportFileFacts = [ReportFileFact(path: csv.path, size: nil, modificationDate: nil)]
        try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: csv.path)
        record.reportFileFacts = [ReportFileFact(path: csv.path, size: UInt64.max, modificationDate: nil)]
        #expect(throws: ReportReplacementOwnershipError.self) {
            try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: csv.path)
        }
        record.reportFileFacts = [ReportFileFact(path: csv.path, size: nil, modificationDate: .distantPast)]
        #expect(throws: ReportReplacementOwnershipError.self) {
            try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: csv.path)
        }
        let pinned = try PinnedReportFile(url: csv)
        record.reportFileFacts = [ReportFileFact(path: csv.path, size: pinned.size,
                                                 modificationDate: pinned.modificationDate)]
        var hiddenPaths: [String: String] = [:]
        let outcomes = TransferJournal.withdrawReports(record: record, paths: files.map(\.path),
            volumeIdentityAt: { _ in record.destinations.first?.volumeID },
            didWithdraw: { hiddenPaths[$0] = $1 })
        #expect(files.allSatisfy { outcomes[$0.path] == .withdrawn })
        // Restore the paths for the source-identity assertion below.
        for file in files {
            let hidden = URL(fileURLWithPath: try #require(hiddenPaths[file.path]))
            try FileManager.default.moveItem(at: hidden, to: file)
        }
        record.reportFileFacts = nil
        record.runSourceURL = source
        #expect(throws: ReportReplacementOwnershipError.self) {
            try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: csv.path)
        }
    }

    @Test func freshReportAndStagingPathsAreRecordedBeforeFirstRename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let old = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("old".utf8),
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        try journal.recordPendingReportPaths(id: id, paths: old.map(\.path), publicationID: id)
        await #expect(throws: (any Error).self) {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8),
                results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true,
                recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0, publicationID: id) },
                beforePublish: { url in
                    let saved = try #require(journal.records.first)
                    let paths = try #require(saved.pendingReportPaths)
                    #expect(paths.contains(url.path))
                    #expect(paths.contains { $0.hasSuffix(".json") && !old.map(\.path).contains($0) })
                    let staging = try #require(saved.reportStagingPath)
                    #expect(FileManager.default.fileExists(atPath: staging + "/" + url.lastPathComponent))
                    throw NSError(domain: "SimulatedStop", code: 1)
                })
        }
    }

    @Test func foreignStagingUsesRecordedSiblingAndSurvivesRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let foreign = backup.appendingPathComponent("Reports/.bitmatch-staging-" + id.uuidString)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("foreign"))
        let date = Date()
        _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil,
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
            safeToErase: false, recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0, publicationID: id) })
        let record = try #require(journal.records.first)
        #expect(record.reportStagingPath?.hasSuffix(id.uuidString + "-2") == true)
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [foreign.path])
        if case .pending = outcomes[foreign.path] {} else { Issue.record("Foreign directory was not retained") }
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("foreign").path))
    }

    @Test func failedRollbackRetainsStagedJSONUntilPublicWithdrawalSucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let failure = Mutex(false)
        let date = Date()
        await #expect(throws: (any Error).self) {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("safe".utf8),
                results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true,
                recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0, publicationID: id) },
                validatePublication: { if failure.withLock({ $0 }) { throw NSError(domain: "rollback", code: 1) } },
                beforePublish: { url in
                    if url.pathExtension == "json" {
                        failure.withLock { $0 = true }
                        throw NSError(domain: "publication", code: 1)
                    }
                })
        }
        let record = try #require(journal.records.first)
        let staging = try #require(record.reportStagingPath)
        let paths = try #require(record.pendingReportPaths)
        let pdf = try #require(paths.first { $0.hasSuffix(".pdf") })
        let json = try #require(paths.first { $0.hasSuffix(".json") })
        let stagedJSON = URL(fileURLWithPath: staging).appendingPathComponent(URL(fileURLWithPath: json).lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: pdf))
        let first = TransferJournal.withdrawReports(record: record, paths: paths + [staging], volumeIdentityAt: { _ in "unavailable" })
        if case .pending = first[staging] {} else { Issue.record("Staged proof was not retained") }
        #expect(FileManager.default.fileExists(atPath: stagedJSON.path))
        let second = TransferJournal.withdrawReports(record: record, paths: paths + [staging])
        #expect(second[pdf] == .withdrawn)
        #expect(second[staging] == .withdrawn)
        #expect(!FileManager.default.fileExists(atPath: staging))
    }

    @Test func recoveryRemovesRecordedStagingDirectoryBeforePublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.json")
        let journal = TransferJournal(fileURL: history, recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let staging = backup.appendingPathComponent("Reports/.bitmatch-staging-" + id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try journal.recordPendingReportPaths(id: id, paths: [staging.path], publicationID: id)
        try Data(id.uuidString.utf8).write(to: staging.appendingPathComponent(".bitmatch-owner"))
        try Data("safe report".utf8).write(to: staging.appendingPathComponent("report.pdf"))
        let record = try #require(journal.records.first)
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [staging.path])
        #expect(outcomes[staging.path] == .withdrawn)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func overrideCannotReplaceAdvancedRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1])
        var old = try #require(journal.records.first)
        let revision = old.revision ?? 0
        old.state = .interrupted
        let row = ResultRow(path: "clip.mov", status: ResultOutcome.verified.statusText, size: 4,
            checksum: "abc", destination: "Backup", destinationPath: backup.appendingPathComponent("clip.mov").path)
        try journal.finish(id: id, results: [row], summary: "Later completion", hadIssues: false)
        #expect(journal.records.first?.state == .completed)
        #expect(try journal.persistInterruptedOverride(old, expectedRevision: revision) == false)
        #expect(journal.records.first?.summary == "Later completion")
    }

    @Test func replacementRejectsForeignOwnershipJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card"), backup = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil,
            results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        let json = try #require(files.first { $0.pathExtension == "json" })
        try JSONSerialization.data(withJSONObject: ["jobId": UUID().uuidString, "source": ["path": source.path]]).write(to: json)
        let record = try #require(journal.records.first)
        let csv = try #require(files.first { $0.pathExtension == "csv" })
        #expect(throws: ReportReplacementOwnershipError.self) {
            try TransferJournal.validateReportReplacement(record: record, paths: files.map(\.path), target: csv.path)
        }
    }
    @Test func replacementDoesNotEnumerateReports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("report-replacement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: nil, results: [], finished: date, checksumAlgorithm: nil, jobID: UUID(),
            started: date, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: nil, results: [], finished: date, checksumAlgorithm: nil, jobID: UUID(),
            started: date, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
            safeToErase: false, replacing: files, reportNames: { _ in throw DeliberateFailure.encode })
    }
    @Test func withdrawnExportsReserveNamesAndRepeatedWithdrawalAvoidsCollisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("withdrawn-exports-\(UUID())")
        let source = root.appendingPathComponent("card")
        let backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let finished = Date()
        var priorFiles: [URL] = []
        for iteration in 0..<2 {
            let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup],
                pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
                jobID: id, started: finished, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
            if iteration == 1 { #expect(Set(files).isDisjoint(with: Set(priorFiles))) }
            try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
            // A pre-existing hidden name for this record must not block withdrawal.
            let collision = files[0].deletingLastPathComponent().appendingPathComponent(".unsettled-\(id.uuidString)-\(files[0].lastPathComponent)")
            try Data("previous".utf8).write(to: collision)
            try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: "Unavailable")
            try journal.retryPendingReportWithdrawals(id: id)
            #expect(journal.records.first { $0.id == id }?.pendingWithdrawalPaths == nil)
            let recorded = try #require(journal.records.first { $0.id == id }?.lastWithdrawnReportPaths)
            #expect(recorded.contains(collision.path + "-1"))
            #expect(recorded.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(try Data(contentsOf: collision) == Data("previous".utf8))
            priorFiles = files
        }
    }
    @Test func withdrawalRetriesWhenHiddenNameAppearsAfterProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("card"), backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard, cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil, results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        let record = try #require(journal.records.first)
        let csv = try #require(files.first { $0.pathExtension == "csv" })
        let hidden = csv.deletingLastPathComponent().appendingPathComponent(ReportName.withdrawnName(report: csv.lastPathComponent, recordID: id))
        let outcomes = TransferJournal.withdrawReports(record: record, paths: files.map(\.path), beforeWithdrawalMove: { url in
            if url == csv { try? Data("collision".utf8).write(to: hidden) }
        }, volumeIdentityAt: { _ in record.destinations.first?.volumeID })
        #expect(files.allSatisfy { outcomes[$0.path] == .withdrawn })
        #expect(try Data(contentsOf: hidden) == Data("collision".utf8))
        #expect(FileManager.default.fileExists(atPath: hidden.path + "-1"))
    }

    @Test(arguments: [false, true])
    func sameSecondExportsWithdrawThroughLiveAndRecoveryPaths(recoveryFirst: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("card"), backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        var firstFiles: [URL] = []
        var firstHidden: [String: String] = [:]
        for iteration in 0..<2 {
            let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup],
                pdfData: Data("export \(iteration)".utf8), results: [], finished: date, checksumAlgorithm: nil,
                jobID: id, started: date, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(), generateFullReport: true,
                projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false,
                reportNames: { _ in [] }) // Simulate a stale directory listing on the second export.
            if iteration == 0 { firstFiles = files } else { #expect(files == firstFiles) }
            try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
            var record = try #require(journal.records.first)
            record.pendingWithdrawalPaths = files.map(\.path)
            var hidden: [String: String] = [:]
            if (iteration == 0) == recoveryFirst {
                let recovered = await TransferJournal.recoverPendingWithdrawals(record)
                #expect(recovered.pendingWithdrawalPaths == nil)
                for path in try #require(recovered.lastWithdrawnReportPaths) {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    if let file = files.first(where: { ReportName.withdrawnReport(name) == $0.lastPathComponent }) {
                        hidden[file.path] = path
                    }
                }
            } else {
                let outcomes = TransferJournal.withdrawReports(record: record, paths: files.map(\.path)) {
                    hidden[$0] = $1
                }
                #expect(files.allSatisfy { outcomes[$0.path] == .withdrawn })
            }
            #expect(hidden.count == files.count)
            for file in files {
                let path = try #require(hidden[file.path])
                #expect(FileManager.default.fileExists(atPath: path))
                if iteration == 1 {
                    #expect(path == (try #require(firstHidden[file.path])) + "-1")
                }
            }
            let pdf = try #require(files.first { $0.pathExtension == "pdf" })
            #expect(try Data(contentsOf: URL(fileURLWithPath: #require(hidden[pdf.path]))) == Data("export \(iteration)".utf8))
            if iteration == 0 { firstHidden = hidden }
        }
        let firstPDF = try #require(firstFiles.first { $0.pathExtension == "pdf" })
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(firstHidden[firstPDF.path]))) == Data("export 0".utf8))
    }

    private enum DeliberateFailure: Error { case encode }

    private struct FailingProject: Codable, Sendable {
        init() {}
        init(from _: Decoder) throws { throw DeliberateFailure.encode }
        func encode(to _: Encoder) throws { throw DeliberateFailure.encode }
    }

    @Test func orphanJSONReservesTheSameSuffixForEveryReportFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("report-names-\(UUID())")
        let source = root.appendingPathComponent("card")
        let backup = root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let finished = Date()
        let name = EvidenceWriter.reportFileName(finished: finished, pathExtension: "json")
        try Data("orphan".utf8).write(to: reports.appendingPathComponent(name))
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup],
            pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
            jobID: id, started: finished, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let stems = files.map { $0.lastPathComponent.components(separatedBy: ".").first! }
        #expect(Set(stems).count == 1)
        #expect(stems[0].hasSuffix("-2"))
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: "backup unavailable")
        try journal.retryPendingReportWithdrawals(id: id)
        #expect(journal.records[0].pendingWithdrawalPaths == nil)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent(name).path))
    }

    @Test func stagingUsesResolvedReportsDirectoryAndIsInvisibleToScanner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-staging-volume-\(UUID())")
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        let actualReports = root.appendingPathComponent("OtherVolume/Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actualReports, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Reports"), withDestinationURL: actualReports)
        defer { try? FileManager.default.removeItem(at: root) }

        try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
            pdfData: Data("%PDF-1.7".utf8), results: [], finished: Date(), checksumAlgorithm: nil,
            jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
            safeToErase: false, beforePDFWrite: {
                let entries = try FileManager.default.contentsOfDirectory(at: actualReports, includingPropertiesForKeys: nil)
                let staging = try #require(entries.first { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
                #expect(staging.resolvingSymlinksInPath().deletingLastPathComponent() == actualReports.resolvingSymlinksInPath())
            })

        let hidden = actualReports.appendingPathComponent(".BitMatch-report-staging-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try Data("{broken".utf8).write(to: hidden.appendingPathComponent("BitMatch_Report_abandoned.json"))
        let scan = await EvidenceReader.scanReports(at: actualReports)
        #expect(scan.reports.count == 1)
        #expect(scan.skipped.isEmpty)
    }

    @Test func failedReplacementKeepsTheOriginalReportDiscoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-replace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("old PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let oldContents = try original.map { try Data(contentsOf: $0) }

        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("new PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: false, beforePDFWrite: { throw DeliberateFailure.encode }, replacing: original)
        }
        #expect(try original.map { try Data(contentsOf: $0) } == oldContents)
        let scan = await EvidenceReader.scanReports(at: root)
        #expect(scan.reports.count == 1)
    }

    @Test func replacementCannotPublishAnUnrecordedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-replace-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let contents = try original.map { try Data(contentsOf: $0) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original)
        }
        #expect(try original.map { try Data(contentsOf: $0) } == contents)
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        #expect(Set(entries.map(\.lastPathComponent)) == Set(original.map(\.lastPathComponent)))
    }

    @Test func jsonIsPublishedLastAndFailedRestoreDoesNotLeaveSafePDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("cautious".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let pdf = try #require(original.first { $0.pathExtension == "pdf" })
        let json = try #require(original.first { $0.pathExtension == "json" })
        let oldJSON = try Data(contentsOf: json)
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original, beforePublish: { url in
                    if url.pathExtension == "json" {
                        #expect(try Data(contentsOf: pdf) == Data("safe".utf8))
                        #expect(try Data(contentsOf: json) == oldJSON)
                        let reports = pdf.deletingLastPathComponent().resolvingSymlinksInPath()
                        let entries = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                        #expect(entries.contains { $0.lastPathComponent.hasSuffix(".sha-256.txt") })
                        #expect(entries.contains { $0.pathExtension == "csv" })
                        let staging = try #require(entries.first { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
                        // Make the actual final rename fail after the PDF published.
                        try FileManager.default.removeItem(at: staging.appendingPathComponent(json.lastPathComponent))
                    }
                }, beforeRestore: { url in
                    if url.pathExtension == "pdf" { throw DeliberateFailure.encode }
                })
        }
        #expect(!FileManager.default.fileExists(atPath: pdf.path))
        #expect(try Data(contentsOf: json) == oldJSON)
    }

    @Test(arguments: ["csv", "txt", "pdf", "json"])
    func publicationFailureLeavesNoSafeJSONOrPDF(failingExtension: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-publish-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: Date(), checksumAlgorithm: .sha256,
                jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforePublish: { url in
                    if url.pathExtension == failingExtension { throw DeliberateFailure.encode }
                })
        }
        let reports = root.appendingPathComponent("Reports")
        let entries = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
        #expect(entries.isEmpty)
    }

    @Test func stagingCleanupFailureFailsExportAndWithdrawsPublishedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: Date(), checksumAlgorithm: nil,
                jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforeStagingRemoval: { _ in throw DeliberateFailure.encode })
        }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test func simultaneousExportsUseDifferentNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-concurrent-reports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        @Sendable func export() async throws -> [URL] {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        }
        async let first = export()
        async let second = export()
        let (firstFiles, secondFiles) = try await (first, second)
        #expect(Set(firstFiles).isDisjoint(with: Set(secondFiles)))
        let scan = await EvidenceReader.scanReports(at: root)
        #expect(scan.reports.count == 2)
    }

    // Plant: remove the digest guard or restore with a replacing rename.
    @Test(arguments: [false, true])
    func rollbackLeavesForeignPublishedOrRestorationOccupant(restoration: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-foreign-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [destination], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let date = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
            pdfData: Data("old".utf8), results: [], finished: date, checksumAlgorithm: nil,
            jobID: id, started: date, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        try journal.recordPendingReportPaths(id: id, paths: original.map(\.path), publicationID: id)
        try recordFixtureFacts(journal, id: id, files: original)
        let pdf = try #require(original.first { $0.pathExtension == "pdf" })
        let foreign = Data("foreign replacement".utf8)
        do {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
                pdfData: Data("new".utf8), results: [], finished: date, checksumAlgorithm: nil,
                jobID: id, started: date, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original,
                recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0, publicationID: id) },
                recordIntendedFacts: { try journal.recordIntendedReportFacts(id: id, facts: $0, publicationID: id) },
                beforePublish: { url in
                    if url.pathExtension == "json" {
                        if !restoration { try foreign.write(to: pdf, options: .atomic) }
                        throw DeliberateFailure.encode
                    }
                }, beforeRestore: { url in
                    if restoration && url == pdf { try foreign.write(to: pdf, options: .atomic) }
                })
            Issue.record("Publication should fail")
        } catch let error as ReportExportError {
            #expect(error.pendingWithdrawalPaths.contains(pdf.path))
            #expect(error.localizedDescription.contains("changed during publication and was left in place"))
            try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: error.localizedDescription,
                                  pendingWithdrawalPaths: error.pendingWithdrawalPaths)
            #expect(journal.records.first?.pendingWithdrawalPaths?.contains(pdf.path) == true)
        }
        #expect(try Data(contentsOf: pdf) == foreign)
    }

    @Test func failedReplacementRestoresAlreadyReplacedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-replace-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("cautious".utf8), results: [], finished: finished, checksumAlgorithm: nil,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let oldContents = try original.map { try Data(contentsOf: $0) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: finished, checksumAlgorithm: nil,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original, beforePublish: { url in
                    if url.pathExtension == "json" { throw DeliberateFailure.encode }
                })
        }
        #expect(try original.map { try Data(contentsOf: $0) } == oldContents)
    }

    @Test func pdfWriteFailureLeavesNoPublishedReportAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-pdf-failure-\(UUID())")
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
                pdfData: Data("%PDF-1.7".utf8), results: [ResultRow(path: "/Card/A", status: ResultOutcome.verified.statusText,
                    size: 4, checksum: "abc", destination: destination.path)],
                finished: Date(), checksumAlgorithm: .sha256, jobID: UUID(), started: Date(), duration: 1,
                sourceURL: URL(fileURLWithPath: "/Card"), fileCount: 1, matchCount: 1, totalBytesProcessed: 4,
                workers: 1, filesPerSecond: 1, prefs: ReportPrefs(verificationMode: .standard),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforePDFWrite: { throw DeliberateFailure.encode })
        }
        let reports = destination.appendingPathComponent("Reports")
        let files = (try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)) ?? []
        #expect(files.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
    }

    @Test func publishedReportRemainsDiscoverableAndStagingIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-staged-report-\(UUID())")
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
            pdfData: Data("%PDF-1.7".utf8), results: [ResultRow(path: "/Card/A", status: ResultOutcome.verified.statusText,
                size: 4, checksum: "abc", destination: destination.path)],
            finished: Date(), checksumAlgorithm: .sha256, jobID: UUID(), started: Date(), duration: 1,
            sourceURL: URL(fileURLWithPath: "/Card"), fileCount: 1, matchCount: 1, totalBytesProcessed: 4,
            workers: 1, filesPerSecond: 1, prefs: ReportPrefs(verificationMode: .standard),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        let scan = await EvidenceReader.scanReports(at: destination)
        #expect(scan.reports.count == 1)
        #expect(scan.reports.first?.url.deletingLastPathComponent().lastPathComponent == "Reports")
        let siblings = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
    }

    @Test func laterEvidenceFailureNeverLeavesAnEarlierPDFVerdict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-evidence-order-\(UUID())", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let finished = Date(timeIntervalSince1970: 1_800_000_060)
        await #expect(throws: (any Error).self) {
            _ = try await EvidenceWriter.write(
                kind: .copyAndVerify,
                destinationURLs: [destination],
                pdfData: Data("%PDF-1.7 safer verdict".utf8),
                results: [ResultRow(
                    path: "/Card/A.mov", status: ResultOutcome.verified.statusText,
                    size: 4, checksum: "abc", destination: destination.path
                )],
                finished: finished,
                checksumAlgorithm: .sha256,
                jobID: UUID(),
                started: Date(timeIntervalSince1970: 1_800_000_000),
                duration: 60,
                sourceURL: URL(fileURLWithPath: "/Card"),
                fileCount: 1,
                matchCount: 1,
                totalBytesProcessed: 4,
                workers: 1,
                filesPerSecond: 1,
                prefs: ReportPrefs(verificationMode: .standard),
                generateFullReport: true,
                projectCSV: nil,
                projectJSON: FailingProject()
            )
        }

        let reports = destination.appendingPathComponent("Reports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reports, includingPropertiesForKeys: nil
        )) ?? []
        #expect(!files.contains { $0.pathExtension == "pdf" })
    }
}
