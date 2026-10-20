import Foundation
import XCTest
@testable import BitMatchEngine

final class SourceFilenameAmbiguityTests: XCTestCase {
    func testCanonicallyEqualByteDistinctPathsAreRefusedInEitherOrder() {
        let pairs = [("K.mov", "\u{212A}.mov"), ("caf\u{E9}.mov", "cafe\u{301}.mov")]
        for (first, second) in pairs {
            XCTAssertEqual(first, second, "This regression needs Swift-equal names")
            XCTAssertNotEqual(Data(first.utf8), Data(second.utf8))
            for paths in [[first, second], [second, first]] {
                assertUnsafe(paths)
            }
        }
    }

    func testRepeatedIdenticalPathCannotBeAnUnambiguousManifest() {
        assertUnsafe(["clip.mov", "clip.mov"])
    }

    func testAsciiCaseAliasesAreRefusedInEitherOrder() {
        for paths in [["clip.mov", "CLIP.mov"], ["CLIP.mov", "clip.mov"]] {
            assertUnsafe(paths)
        }
    }

    func testEachSingleCanonicalSpellingIsAllowed() {
        for path in ["K.mov", "\u{212A}.mov", "caf\u{E9}.mov", "cafe\u{301}.mov"] {
            XCTAssertNoThrow(try SafetyValidator.validatePortableRelativePaths([path]))
        }
    }

    func testDistinctEmojiAndPathsInSeparateDirectoriesRemainAllowed() {
        XCTAssertNoThrow(try SafetyValidator.validatePortableRelativePaths([
            "\u{1F469}\u{200D}\u{1F4BB}.mov", "\u{1F469}\u{1F4BB}.mov",
            "\u{1F3AC}.mov", "\u{1F3AC}\u{FE0F}.mov", "日本語.mov",
            "nfc/caf\u{E9}.mov", "nfd/cafe\u{301}.mov"
        ]))
    }

    func testDestinationCanonicalAliasesAreRefusedWithoutDiscardingAnEntry() {
        for names in [["K.mov", "\u{212A}.mov"], ["\u{212A}.mov", "K.mov"], ["caf\u{E9}.mov", "cafe\u{301}.mov"]] {
            XCTAssertThrowsError(try uniqueDestinationMetadata(names.map(entry))) { error in
                let failure = error as NSError
                XCTAssertEqual(failure.domain, "TransferPipeline")
                XCTAssertEqual(failure.code, NSFileReadUnknownError)
                XCTAssertTrue(failure.localizedDescription.contains("Unicode-equivalent"))
            }
        }
    }

    func testDestinationCaseVariantsAndUnrelatedUnicodeExtrasRemainDistinct() throws {
        let names = ["clip.mov", "CLIP.mov", "nfc/caf\u{E9}.mov", "nfd/cafe\u{301}.mov", "\u{1F469}\u{200D}\u{1F4BB}.mov", "\u{1F469}\u{1F4BB}.mov"]
        let actual = try uniqueDestinationMetadata(names.map(entry))
        XCTAssertEqual(actual.count, names.count)
        for name in names { XCTAssertEqual(actual[name]?.relativePath, name) }
    }

    private func entry(_ path: String) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/synthetic").appendingPathComponent(path), relativePath: path, size: 1)
    }

    private func assertUnsafe(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SafetyValidator.validatePortableRelativePaths(paths), file: file, line: line) { error in
            guard case FileOperationError.unsafeOperation = error else {
                return XCTFail("Expected an unsafe source error, got \(error)", file: file, line: line)
            }
        }
    }
}
