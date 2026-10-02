// EvidenceGoldenTests.swift
// Task T14 of the engine-package move: the evidence
// files must stay byte-identical while the engine moves into a package
// (Promise 3). The literals below were produced by main at 3dcd279, before
// any engine code moved. Paths do not exist, so the drive, free-space and
// file-size probes in the JSON give fixed answers on any machine.
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct EvidenceGoldenTests {
    private static let started = Date(timeIntervalSince1970: 1_800_000_000)
    private static let finished = Date(timeIntervalSince1970: 1_800_000_075)
    private static let jobID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    /// One row per `ResultOutcome`, plus a legacy text row and a path that
    /// needs CSV quoting and formula neutralizing.
    private static let rows: [ResultRow] = [
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000B01")!,
                  path: "/golden-missing/CARD/A001C001.MXF", status: ResultOutcome.verified.statusText,
                  size: 1_048_576, checksum: "aa11", destination: "SSD A",
                  destinationPath: "/golden-missing/SSD A/CARD/A001C001.MXF"),
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000B02")!,
                  path: "/golden-missing/CARD/A001C002.MXF", status: ResultOutcome.copiedUnverified.statusText,
                  size: 2_048, checksum: nil, destination: "SSD A",
                  destinationPath: "/golden-missing/SSD A/CARD/A001C002.MXF"),
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000B03")!,
                  path: "/golden-missing/CARD/A001C003.MXF", status: ResultOutcome.checksumMismatch.statusText,
                  size: 4_096, checksum: "cc33", destination: "SSD A",
                  destinationPath: "/golden-missing/SSD A/CARD/A001C003.MXF"),
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000B04")!,
                  path: "/golden-missing/CARD/A001C004.MXF", status: ResultOutcome.failed.statusText,
                  size: 0, checksum: nil, destination: "SSD A", destinationPath: nil),
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000B05")!,
                  path: "/golden-missing/CARD/=cmd, \"quoted\".WAV", status: "✅ Match",
                  size: 10, checksum: "ee55", destination: "SSD A",
                  destinationPath: "/golden-missing/SSD A/CARD/=cmd, \"quoted\".WAV"),
    ]

    private static var prefs: ReportPrefs {
        var prefs = ReportPrefs(makeReport: true)
        prefs.verificationMode = .standard
        prefs.notes = "Shot day 3, \"B\" camera."
        return prefs
    }

    @Test func csvIsUnchanged() throws {
        let csv = try ReportExporter.makeEnhancedCSV(
            results: Self.rows, started: Self.started, duration: 75, filesPerSecond: 0.07,
            photographerContext: nil, prefs: Self.prefs
        )
        try Self.check(csv, against: Self.expectedCSV, name: "csv")
    }

    @Test func projectCSVIsUnchanged() throws {
        let csv = try ReportExporter.makeEnhancedCSV(
            results: Self.projectRows, started: Self.started, duration: 75, filesPerSecond: 0.03,
            photographerContext: Self.projectContext, prefs: Self.prefs
        )
        try Self.check(csv, against: Self.expectedProjectCSV, name: "project-csv")
    }

    @Test func jsonIsUnchanged() throws {
        let json = try Self.json(rows: Self.rows, context: nil)
        try Self.check(json, against: Self.expectedJSON, name: "json")
    }

    // Source totals now describe the 100-byte RAW and 50-byte JPEG rather
    // than the unrelated processed-byte argument. All other golden fields stay fixed.
    @Test func projectJSONRecordsActualSourceBytes() throws {
        let json = try Self.json(rows: Self.projectRows, context: Self.projectContext)
        try Self.check(json, against: Self.expectedProjectJSON, name: "project-json")
    }

    @Test func checksumManifestIsUnchanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString).sha256")
        defer { try? FileManager.default.removeItem(at: url) }
        let verifiedOnly = Self.rows.filter { $0.isSuccessStatus && $0.checksum != nil }
        try EvidenceWriter.writeRecordedChecksumManifest(results: verifiedOnly, algorithm: .sha256, to: url)
        try Self.check(String(contentsOf: url, encoding: .utf8), against: Self.expectedManifest, name: "manifest")
    }

    // MARK: - Helpers

    private static func json(rows: [ResultRow], context: PhotographerReportContext?) throws -> String {
        let report = try ReportExporter.makeEnhancedJSONReport(
            results: rows, jobID: jobID, started: started, finished: finished, mode: .copyAndVerify,
            sourceURL: URL(fileURLWithPath: "/golden-missing/CARD"),
            destinationURLs: [URL(fileURLWithPath: "/golden-missing/SSD A")],
            fileCount: rows.count, matchCount: 1, totalBytesProcessed: 1_054_730, duration: 75,
            workers: 2, prefs: prefs, photographerContext: context
        )
        return String(decoding: try EvidenceWriter.encodeEnhancedJSONReport(report), as: UTF8.self)
    }

    /// Compares, and on a mismatch writes the actual text next to the test
    /// run so a deliberate format change can be reviewed and pasted in.
    private static func check(_ actual: String, against expected: String, name: String) throws {
        if actual != expected {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("EvidenceGolden-\(name).txt")
            try actual.write(to: out, atomically: true, encoding: .utf8)
            Issue.record("\(name) changed; actual written to \(out.path)")
        }
    }

    private static let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000C02")!

    private static let projectRows: [ResultRow] = [
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000C10")!,
                  path: "/golden-missing/CARD/DCIM/100MEDIA/DSC0001.ARW", status: ResultOutcome.verified.statusText,
                  size: 100, checksum: "raw-checksum", destination: "LOCAL",
                  destinationPath: "/golden-missing/LOCAL/package/DSC0001.ARW"),
        ResultRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000C11")!,
                  path: "/golden-missing/CARD/DCIM/100MEDIA/DSC0001.JPG", status: ResultOutcome.verified.statusText,
                  size: 50, checksum: "jpg-checksum", destination: "LOCAL",
                  destinationPath: "/golden-missing/LOCAL/package/DSC0001.JPG"),
    ]

    private static var projectContext: PhotographerReportContext {
        let eventDate = Date(timeIntervalSince1970: 1_752_499_800)
        let safeAt = Date(timeIntervalSince1970: 1_752_503_400)
        let photographerID = UUID(uuidString: "00000000-0000-0000-0000-000000000C01")!
        let card = CardIngest(
            id: cardID,
            provenance: CardProvenance(
                photographerID: photographerID, photographerName: "Mike", cameraName: "Sony A7 IV",
                cardNumber: 1, preliminaryFingerprint: "preliminary-fingerprint",
                confirmedFingerprint: "confirmed-fingerprint"
            ),
            sourceDisplayName: "CARD",
            renderedRelativePath: "2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001",
            localState: .locallySafe, startedAt: eventDate, locallySafeAt: safeAt,
            fileCount: 2, totalBytes: 150, verifiedDestinationCount: 2
        )
        let job = PhotographerJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000C00")!,
            eventDate: eventDate, clientName: "Smith", jobName: "Smith Wedding", eventType: .wedding,
            photographers: [PhotographerIdentity(id: photographerID, name: "Mike")],
            recipe: .wedding, requiredLocalCopyCount: 2, cardIngests: [card],
            createdAt: eventDate, updatedAt: safeAt
        )
        let analysis = CardAnalysis(
            fingerprint: "preliminary-fingerprint", fileCount: 2, totalBytes: 150,
            companionGroups: [PhotoCompanionGroup(
                stem: "dcim/100media/dsc0001",
                rawPaths: ["DCIM/100MEDIA/DSC0001.ARW"], jpegPaths: ["DCIM/100MEDIA/DSC0001.JPG"], sidecarPaths: []
            )]
        )
        return PhotographerReportContext(
            job: job, cardIngestID: cardID, analysis: analysis,
            verifiedDestinationCount: 2, warnings: ["Duplicate fingerprint matches Card 004."]
        )
    }

    // MARK: - Golden text (captured from main at 3dcd279)

    private static let expectedCSV = #"""
Status,File Path,Target Path,Job,Photographer,Camera,Card,Package Path,Details,Timestamp,Bytes,Checksum
✅ Verified,/golden-missing/CARD/A001C001.MXF,/golden-missing/SSD A/CARD/A001C001.MXF,,,,,,Verified,,1048576,aa11
✅ Copied,/golden-missing/CARD/A001C002.MXF,/golden-missing/SSD A/CARD/A001C002.MXF,,,,,,✅ Copied,,2048,
⚠️ Checksum Mismatch,/golden-missing/CARD/A001C003.MXF,/golden-missing/SSD A/CARD/A001C003.MXF,,,,,,⚠️ Checksum Mismatch,,4096,cc33
❌ Failed,/golden-missing/CARD/A001C004.MXF,SSD A,,,,,,❌ Failed,,0,
✅ Match,"/golden-missing/CARD/=cmd, ""quoted"".WAV","/golden-missing/SSD A/CARD/=cmd, ""quoted"".WAV",,,,,,Verified,,10,ee55

# Summary
Total Files,5
Started,2027-01-15T08:00:00Z
Finished,2027-01-15T08:01:15Z
Verified,2
"Copied, not verified",1
Issues,2
Duration,75.00 seconds
Files/Second,0.07
Verification,SHA-256 checksum
Notes,"Shot day 3, ""B"" camera."

"""#

    private static let expectedProjectCSV = #"""
Status,File Path,Target Path,Job,Photographer,Camera,Card,Package Path,Details,Timestamp,Bytes,Checksum
✅ Verified,/golden-missing/CARD/DCIM/100MEDIA/DSC0001.ARW,/golden-missing/LOCAL/package/DSC0001.ARW,Smith Wedding,Mike,Sony A7 IV,Card 001,2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001,Verified,,100,raw-checksum
✅ Verified,/golden-missing/CARD/DCIM/100MEDIA/DSC0001.JPG,/golden-missing/LOCAL/package/DSC0001.JPG,Smith Wedding,Mike,Sony A7 IV,Card 001,2025-07-14_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001,Verified,,50,jpg-checksum

# Summary
Total Files,2
Started,2027-01-15T08:00:00Z
Finished,2027-01-15T08:01:15Z
Verified,2
"Copied, not verified",0
Issues,0
Duration,75.00 seconds
Files/Second,0.03
Locally Safe,No
Fully Backed Up,—
Verification,SHA-256 checksum
Notes,"Shot day 3, ""B"" camera."

"""#

    private static let expectedJSON = #"""
{
  "destinations" : [
    {
      "availableSpace" : 0,
      "driveType" : "Unknown",
      "name" : "SSD A",
      "path" : "\/golden-missing\/SSD A"
    }
  ],
  "extensions" : {
    "MXF" : 4,
    "WAV" : 1
  },
  "jobId" : "00000000-0000-0000-0000-0000000000A1",
  "mode" : "copy-and-verify",
  "notes" : "Shot day 3, \"B\" camera.",
  "performance" : {
    "averageSpeedMBps" : 0.013411585489908855,
    "filesPerSecond" : 0.06666666666666667,
    "throughputMBps" : 0.013411585489908855,
    "totalDuration" : 75,
    "workers" : 2
  },
  "reportVersion" : "3.0",
  "results" : [
    {
      "byteCount" : 1048576,
      "checksum" : "aa11",
      "fileExtension" : "MXF",
      "path" : "\/golden-missing\/CARD\/A001C001.MXF",
      "status" : "✅ Verified",
      "target" : "\/golden-missing\/SSD A\/CARD\/A001C001.MXF"
    },
    {
      "byteCount" : 2048,
      "fileExtension" : "MXF",
      "path" : "\/golden-missing\/CARD\/A001C002.MXF",
      "status" : "✅ Copied",
      "target" : "\/golden-missing\/SSD A\/CARD\/A001C002.MXF"
    },
    {
      "byteCount" : 4096,
      "checksum" : "cc33",
      "fileExtension" : "MXF",
      "path" : "\/golden-missing\/CARD\/A001C003.MXF",
      "status" : "⚠️ Checksum Mismatch",
      "target" : "\/golden-missing\/SSD A\/CARD\/A001C003.MXF"
    },
    {
      "byteCount" : 0,
      "fileExtension" : "MXF",
      "path" : "\/golden-missing\/CARD\/A001C004.MXF",
      "status" : "❌ Failed",
      "target" : "SSD A"
    },
    {
      "byteCount" : 10,
      "checksum" : "ee55",
      "fileExtension" : "WAV",
      "path" : "\/golden-missing\/CARD\/=cmd, \"quoted\".WAV",
      "status" : "✅ Match",
      "target" : "\/golden-missing\/SSD A\/CARD\/=cmd, \"quoted\".WAV"
    }
  ],
  "source" : {
    "driveType" : "Unknown",
    "fileCount" : 5,
    "name" : "CARD",
    "path" : "\/golden-missing\/CARD",
    "totalSize" : 1054730
  },
  "statistics" : {
    "averageFileSize" : 210946,
    "issues" : 2,
    "matches" : 1,
    "successRate" : 20,
    "totalBytes" : 1054730,
    "totalFiles" : 5
  },
  "timestamp" : "2027-01-15T08:01:15Z",
  "verification" : {
    "algorithm" : "SHA-256",
    "issuesByType" : {
      "⚠️ Checksum Mismatch" : 1,
      "❌ Failed" : 1
    },
    "method" : "checksum"
  }
}
"""#

    private static let expectedProjectJSON = #"""
{
  "destinations" : [
    {
      "availableSpace" : 0,
      "driveType" : "Unknown",
      "name" : "SSD A",
      "path" : "\/golden-missing\/SSD A"
    }
  ],
  "extensions" : {
    "ARW" : 1,
    "JPG" : 1
  },
  "jobId" : "00000000-0000-0000-0000-0000000000A1",
  "mode" : "copy-and-verify",
  "notes" : "Shot day 3, \"B\" camera.",
  "performance" : {
    "averageSpeedMBps" : 0.013411585489908855,
    "filesPerSecond" : 0.02666666666666667,
    "throughputMBps" : 0.013411585489908855,
    "totalDuration" : 75,
    "workers" : 2
  },
  "photographyJob" : {
    "analysis" : {
      "companionGroups" : [
        {
          "jpegPaths" : [
            "DCIM\/100MEDIA\/DSC0001.JPG"
          ],
          "rawPaths" : [
            "DCIM\/100MEDIA\/DSC0001.ARW"
          ],
          "sidecarPaths" : [

          ],
          "stem" : "dcim\/100media\/dsc0001"
        }
      ],
      "fileCount" : 2,
      "fingerprint" : "preliminary-fingerprint",
      "sourcePaths" : [

      ],
      "totalBytes" : 150
    },
    "card" : {
      "fileCount" : 2,
      "id" : "00000000-0000-0000-0000-000000000C02",
      "localState" : "issues",
      "provenance" : {
        "cameraName" : "Sony A7 IV",
        "cardNumber" : 1,
        "photographerID" : "00000000-0000-0000-0000-000000000C01",
        "photographerName" : "Mike",
        "preliminaryFingerprint" : "preliminary-fingerprint"
      },
      "remoteBackupSummaries" : [

      ],
      "renderedRelativePath" : "2025-07-14_Smith-Wedding\/Originals\/Mike\/Sony-A7-IV\/Card-001",
      "sourceDisplayName" : "CARD",
      "startedAt" : "2025-07-14T13:30:00Z",
      "totalBytes" : 150,
      "verifiedDestinationCount" : 0
    },
    "clientName" : "Smith",
    "companionCounts" : {
      "jpeg" : 1,
      "raw" : 1,
      "sidecar" : 0
    },
    "eventDate" : "2025-07-14T13:30:00Z",
    "eventType" : "Wedding",
    "jobID" : "00000000-0000-0000-0000-000000000C00",
    "jobName" : "Smith Wedding",
    "remoteBackupEvidence" : [

    ],
    "requiredLocalCopyCount" : 2,
    "results" : [
      {
        "checksum" : "raw-checksum",
        "destination" : "LOCAL",
        "destinationPath" : "\/golden-missing\/LOCAL\/package\/DSC0001.ARW",
        "id" : "00000000-0000-0000-0000-000000000C10",
        "path" : "\/golden-missing\/CARD\/DCIM\/100MEDIA\/DSC0001.ARW",
        "size" : 100,
        "status" : "✅ Verified",
        "successful" : true
      },
      {
        "checksum" : "jpg-checksum",
        "destination" : "LOCAL",
        "destinationPath" : "\/golden-missing\/LOCAL\/package\/DSC0001.JPG",
        "id" : "00000000-0000-0000-0000-000000000C11",
        "path" : "\/golden-missing\/CARD\/DCIM\/100MEDIA\/DSC0001.JPG",
        "size" : 50,
        "status" : "✅ Verified",
        "successful" : true
      }
    ],
    "verifiedDestinationCount" : 0,
    "warnings" : [
      "Duplicate fingerprint matches Card 004."
    ]
  },
  "reportVersion" : "3.0",
  "results" : [
    {
      "byteCount" : 100,
      "checksum" : "raw-checksum",
      "fileExtension" : "ARW",
      "path" : "\/golden-missing\/CARD\/DCIM\/100MEDIA\/DSC0001.ARW",
      "status" : "✅ Verified",
      "target" : "\/golden-missing\/LOCAL\/package\/DSC0001.ARW"
    },
    {
      "byteCount" : 50,
      "checksum" : "jpg-checksum",
      "fileExtension" : "JPG",
      "path" : "\/golden-missing\/CARD\/DCIM\/100MEDIA\/DSC0001.JPG",
      "status" : "✅ Verified",
      "target" : "\/golden-missing\/LOCAL\/package\/DSC0001.JPG"
    }
  ],
  "source" : {
    "driveType" : "Unknown",
    "fileCount" : 2,
    "name" : "CARD",
    "path" : "\/golden-missing\/CARD",
    "totalSize" : 150
  },
  "statistics" : {
    "averageFileSize" : 527365,
    "issues" : 0,
    "matches" : 1,
    "successRate" : 50,
    "totalBytes" : 1054730,
    "totalFiles" : 2
  },
  "timestamp" : "2027-01-15T08:01:15Z",
  "verification" : {
    "algorithm" : "SHA-256",
    "issuesByType" : {

    },
    "method" : "checksum"
  }
}
"""#

    private static let expectedManifest = #"""
# BitMatch Checksum Manifest
# Algorithm: SHA-256
# Format: CHECKSUM  FILENAME

aa11  /golden-missing/SSD A/CARD/A001C001.MXF
ee55  /golden-missing/SSD A/CARD/=cmd, "quoted".WAV

"""#

}
