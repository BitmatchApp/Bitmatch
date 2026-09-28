// DemoQueueSeeder.swift - DEBUG-only screenshot scenario for the transfer queue.
//
// Launch a DEBUG build with -BitMatchDemoQueue: on launch it builds a fake
// three Sony cards in the app's temporary directory, two backup folders in the
// app's Documents directory, enqueues three real transfers through
// SharedAppCoordinator and starts the real queue. The queue then shows a
// running row, waiting rows, and (Card A finishes in seconds) a
// finished safe-to-erase row. No fake UI state; the real engine copies real
// files. Nothing in this file compiles into Release.
//
// Screenshot helpers (each implies the demo; combinable):
// -BitMatchDemoSlow throttles the demo copies to ~16 MB/s through
// DestinationWriter.FanOutHooks so the running card stays mid-copy for
// ~90 s. -BitMatchDemoOpenQueue opens the queue automatically after
// seeding (sheet on compact, inspector on regular). Every demo launch
// first drops the previous session's queue rows so counts start fresh
// ("1 of 3", never "6 of 6").
#if DEBUG
import Foundation
import BitMatchEngine

/// Fixture folders for the demo queue: three Sony cards in tmp, two backups
/// in Documents.
enum DemoQueueFixtures {
    struct Layout: Sendable {
        let root: URL
        let cardA: URL
        let cardB: URL
        let cardC: URL
        let backupA: URL
        let backupB: URL
    }

    /// Size of the big card's main clip. 1.5 GB of real (non-sparse) bytes
    /// keeps the running state visible for about a minute in the simulator.
    /// Tests pass a small value; the seeder uses the default.
    static let defaultBigFileBytes: Int64 = 1_500 * 1024 * 1024

    static func build(
        bigFileBytes: Int64 = defaultBigFileBytes,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        documentsDirectory: URL? = nil
    ) throws -> Layout {
        let fileManager = FileManager.default
        let root = temporaryDirectory
            .appendingPathComponent("bitmatch_demo_\(UUID().uuidString)", isDirectory: true)
        let cardA = root.appendingPathComponent("CardA", isDirectory: true)
        let cardB = root.appendingPathComponent("CardB", isDirectory: true)
        let cardC = root.appendingPathComponent("CardC", isDirectory: true)
        let documents = try documentsDirectory ?? fileManager.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let backupA = documents.appendingPathComponent("BitMatchDemoBackup-A", isDirectory: true)
        let backupB = documents.appendingPathComponent("BitMatchDemoBackup-B", isDirectory: true)

        for backup in [backupA, backupB] where fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }

        for card in [cardA, cardB, cardC] {
            try fileManager.createDirectory(
                at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for backup in [backupA, backupB] {
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        }

        // Card B has one large real file plus a few small ones.
        try writeRealBytes(
            count: bigFileBytes,
            to: cardB.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        )
        try Data(repeating: 0xA5, count: 128 * 1024).write(
            to: cardB.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002.MP4")
        )
        try Data("<clip>C0001</clip>".utf8).write(
            to: cardB.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001M01.XML")
        )
        try Data("<mediaPro/>".utf8).write(
            to: cardB.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        )

        // Tiny card: finishes in a couple of seconds once running.
        try Data(repeating: 0x5A, count: 128 * 1024).write(
            to: cardA.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C9001.MP4")
        )
        try Data("<clip>C9001</clip>".utf8).write(
            to: cardA.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C9001M01.XML")
        )
        try Data("<mediaPro/>".utf8).write(
            to: cardA.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        )

        try Data(repeating: 0x3C, count: 128 * 1024).write(
            to: cardC.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C8001.MP4")
        )
        try Data("<clip>C8001</clip>".utf8).write(
            to: cardC.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C8001M01.XML")
        )
        try Data("<mediaPro/>".utf8).write(
            to: cardC.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        )

        return Layout(root: root, cardA: cardA, cardB: cardB, cardC: cardC, backupA: backupA, backupB: backupB)
    }

    /// Writes `count` bytes of generated (never sparse, never a hole) data.
    /// One 1 MB buffer is filled once from a xorshift stream and rewritten
    /// with the chunk index mixed into its head, so every chunk allocates
    /// real blocks with non-identical content.
    private static func writeRealBytes(count: Int64, to url: URL) throws {
        precondition(count > 0)
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for index in buffer.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            buffer[index] = UInt8(truncatingIfNeeded: state)
        }
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = count
        var chunk: UInt64 = 0
        while remaining > 0 {
            let bytes = Int(min(remaining, Int64(buffer.count)))
            withUnsafeBytes(of: chunk.bigEndian) { head in
                for (offset, byte) in head.enumerated() {
                    buffer[offset] = buffer[offset] ^ byte
                }
            }
            try handle.write(contentsOf: buffer.prefix(bytes))
            withUnsafeBytes(of: chunk.bigEndian) { head in
                for (offset, byte) in head.enumerated() {
                    buffer[offset] = buffer[offset] ^ byte
                }
            }
            chunk &+= 1
            remaining -= Int64(bytes)
        }
    }
}

/// Seeds the demo queue on flagged DEBUG launches. Called from each app's
/// root view; inert in every other launch.
@MainActor
enum DemoQueueSeeder {
    /// Launch argument that triggers the scenario, e.g.
    /// `xcrun simctl launch booted <bundle> -BitMatchDemoQueue`.
    static let launchArgument = "-BitMatchDemoQueue"
    /// Screenshot helper: implies the demo and throttles its copies so the
    /// running card stays mid-copy for ~90 s. Demo path only.
    static let slowLaunchArgument = "-BitMatchDemoSlow"
    /// Screenshot helper: implies the demo and opens the queue automatically
    /// after seeding (sheet on compact, inspector on regular).
    static let openQueueLaunchArgument = "-BitMatchDemoOpenQueue"

    /// One seeding per process; root-view onAppear can fire more than once.
    private static var didSeedThisLaunch = false

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(launchArgument)
            || arguments.contains(slowLaunchArgument)
            || arguments.contains(openQueueLaunchArgument)
    }

    static var isSlowRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(slowLaunchArgument)
    }

    static var isOpenQueueRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(openQueueLaunchArgument)
    }

    /// Effective copy rate for `-BitMatchDemoSlow`. The 1.5 GB card takes
    /// ~90 s at this rate, so the running row stays mid-copy for screenshots
    /// on any disk speed. (A literal 40 MB/s would finish it in ~38 s.)
    static let slowBytesPerSecond: Double = 16 * 1024 * 1024

    /// Throttles one copy to `slowBytesPerSecond` by sleeping per source
    /// read, proportionally to the bytes just read. Returns the data
    /// unchanged, so verification still sees the true card bytes.
    /// Cancellation surfaces as a thrown CancellationError, which the
    /// fan-out loop already treats as cancellation.
    static var slowCopyHooks: DestinationWriter.FanOutHooks {
        DestinationWriter.FanOutHooks(sourceDidRead: { _, data in
            try await Task.sleep(for: .seconds(Double(data.count) / slowBytesPerSecond))
            return data
        })
    }

    /// Safe to call from every launch: only a flagged launch seeds, once.
    static func seedIfRequested(coordinator: SharedAppCoordinator) {
        guard isRequested, !didSeedThisLaunch else { return }
        didSeedThisLaunch = true
        Task { await seed(coordinator) }
    }

    @discardableResult
    static func enqueueDemo(
        layout: DemoQueueFixtures.Layout,
        coordinator: SharedAppCoordinator,
        startsQueue: Bool
    ) throws -> [UUID] {
        var ids: [UUID] = []
        ids.append(try coordinator.enqueue(
            source: layout.cardA, destinations: [layout.backupA], verificationMode: .standard
        ))
        ids.append(try coordinator.enqueue(
            source: layout.cardB, destinations: [layout.backupA], verificationMode: .standard
        ))
        ids.append(try coordinator.enqueue(
            source: layout.cardC, destinations: [layout.backupB], verificationMode: .standard
        ))
        // Registered before the queue starts: the first run reads its hooks
        // when its config is built, which happens after startQueue returns.
        if isSlowRequested { coordinator.demoSlowRecordIDs.formUnion(ids) }
        if startsQueue { coordinator.startQueue() }
        return ids
    }

    private static func seed(_ coordinator: SharedAppCoordinator) async {
        guard !coordinator.isOperationInProgress, !coordinator.queueIsRunning else {
            SharedLogger.info(
                "Demo queue skipped: a transfer or queue is already running.",
                category: .transfer
            )
            return
        }
        // Counts start fresh: drop the previous session's queue rows before
        // the new cards land, so the queue reads "1 of 3", not "6 of 6".
        // History records are untouched.
        coordinator.resetQueueSessionForDemo()
        do {
            // The large write stays off the main actor; the UI is usable
            // while the fixture lands, and the queue starts once it has.
            let layout = try await Task.detached(priority: .userInitiated) {
                try DemoQueueFixtures.build()
            }.value
            // Card A finishes within seconds, leaving a finished row above
            // the long-running Card B transfer and waiting Card C.
            try enqueueDemo(layout: layout, coordinator: coordinator, startsQueue: true)
            if isOpenQueueRequested { coordinator.demoQueueAutoOpen = true }
            SharedLogger.info(
                "Demo queue started: Card A, Card B, and Card C.",
                category: .transfer
            )
        } catch {
            SharedLogger.warning(
                "Demo queue did not start: \(error.localizedDescription)",
                category: .transfer
            )
        }
    }
}
#endif
