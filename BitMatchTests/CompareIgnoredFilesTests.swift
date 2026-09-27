// CompareIgnoredFilesTests.swift
// Regression coverage for GitHub issue #8: comparing a camera card against its
// offload reported "1 only in destination" because Finder wrote a .DS_Store into
// the destination folder after the copy.
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

#if os(macOS)
struct CompareIgnoredFilesTests {

    private struct Fixture {
        let root: URL
        let card: URL
        let offload: URL

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("bitmatch_compare_ignore_\(UUID().uuidString)")
            card = root.appendingPathComponent("card")
            offload = root.appendingPathComponent("offload")
            for base in [card, offload] {
                try fm.createDirectory(at: base.appendingPathComponent("Clip"), withIntermediateDirectories: true)
                try Data("clip-one".utf8).write(to: base.appendingPathComponent("Clip/A001C001.mxf"))
                try Data("<xml/>".utf8).write(to: base.appendingPathComponent("Clip/A001C001M01.xml"))
            }
        }

        func write(_ relativePath: String, in base: URL, _ contents: String = "x") throws {
            let url = base.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        func compare() async throws -> CompareStats {
            let coordinator = await MainActor.run { ComparisonCoordinator(platformManager: MacOSPlatformManager.shared) }
            return try await coordinator.compareFolders(
                left: card, right: offload, verificationMode: .standard, onProgress: { _ in }
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test
    func finderMetadataInDestinationIsNotADifference() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".DS_Store", in: f.offload)
        try f.write("Clip/.DS_Store", in: f.offload)
        try f.write("Clip/._A001C001.mxf", in: f.offload)
        try f.write("Icon\r", in: f.offload)

        let stats = try await f.compare()

        #expect(stats.onlyInRightPaths == [])
        #expect(stats.isClean)
        #expect(stats.commonCount == 2)
    }

    @Test
    func finderMetadataOnSourceIsADifference() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // A card-side AppleDouble sidecar (and card-side view state) that was
        // never copied is a real gap: doubt fails closed.
        try f.write("Clip/._A001C001.mxf", in: f.card)
        try f.write(".DS_Store", in: f.card)

        let stats = try await f.compare()

        #expect(stats.onlyInLeftPaths.contains("Clip/._A001C001.mxf"))
        #expect(stats.onlyInLeftPaths.contains(".DS_Store"))
        #expect(stats.onlyInRightPaths == [])
        #expect(!stats.isClean)
    }

    @Test
    func finderMetadataOnBothSidesIsNotAMismatch() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".DS_Store", in: f.card, "card view settings")
        try f.write(".DS_Store", in: f.offload, "different offload view settings")

        let stats = try await f.compare()

        #expect(stats.mismatchedPaths == [])
        #expect(stats.isClean)
    }

    @Test
    func offloadManifestsAtDestinationRootAreNotADifference() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        // ASC MHL history written by current BitMatch.
        try f.write("ascmhl/0001_BitMatch_2026-09-25_120000Z.mhl", in: f.offload)
        try f.write("ascmhl/ascmhl_chain.xml", in: f.offload)
        // Legacy MHL pair written by BitMatch 0.1.4 paranoid transfers.
        try f.write("card_20260925_120000.mhl", in: f.offload)
        try f.write("card_20260925_120000.mhl.md5", in: f.offload)

        let stats = try await f.compare()

        #expect(stats.onlyInRightPaths == [])
        #expect(stats.isClean)
    }

    @Test
    func realExtraFilesAreStillReported() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("Clip/A001C002.mxf", in: f.offload)
        // A manifest below the root is not an offload manifest for this compare.
        try f.write("Clip/notes.mhl", in: f.offload)
        // A manifest that exists on the source but was not copied is a real gap.
        try f.write("ascmhl/ascmhl_chain.xml", in: f.card)

        let stats = try await f.compare()

        #expect(stats.onlyInRightPaths == ["Clip/A001C002.mxf", "Clip/notes.mhl"])
        #expect(stats.onlyInLeftPaths == ["ascmhl/ascmhl_chain.xml"])
        #expect(!stats.isClean)
    }
}
#endif
