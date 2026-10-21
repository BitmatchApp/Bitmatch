import Foundation
import Testing
@testable import BitMatchEngine

struct TransferIOMeterTests {
    @Test func ratesSeparateFastAndSlowDestinationsAndReadback() throws {
        let meter = TransferIOMeter(destinationCount: 2)
        let chunk = 4 * 1024 * 1024

        let first = try #require(meter.record(destination: 0, phase: .writing,
                                              bytes: chunk, duration: 0.1, now: 10))
        #expect(first.destinations[0].writtenBytes == Int64(chunk))
        #expect(first.destinations[0].writeBytesPerSecond == nil)
        #expect(first.destinations[1].writtenBytes == 0)

        _ = meter.record(destination: 1, phase: .writing, bytes: chunk, duration: 0.5, now: 10.3)
        _ = meter.record(destination: 0, phase: .writing, bytes: chunk, duration: 0.1, now: 10.6)
        _ = meter.record(destination: 1, phase: .writing, bytes: chunk, duration: 0.5, now: 10.9)
        let writes = meter.finalSnapshot(now: 10.9)
        #expect(writes.destinations.map(\.writtenBytes) == [Int64(chunk * 2), Int64(chunk * 2)])
        #expect((writes.destinations[0].writeBytesPerSecond ?? 0) >
                (writes.destinations[1].writeBytesPerSecond ?? 0) * 4)
        #expect(writes.destinations.allSatisfy { $0.readbackBytes == 0 })

        _ = meter.record(destination: 1, phase: .readingBack, bytes: chunk, duration: 0.2, now: 11.2)
        _ = meter.record(destination: 1, phase: .readingBack, bytes: chunk, duration: 0.2, now: 11.5)
        let read = meter.finalSnapshot(now: 11.5)
        #expect(read.destinations[0].readbackBytes == 0)
        #expect(read.destinations[1].readbackBytes == Int64(chunk * 2))
        #expect((read.destinations[1].readbackBytesPerSecond ?? 0) > 0)
        #expect(read.sequence > writes.sequence)
    }

    @Test func invalidSamplesAndSilentDestinationsCannotInventSpeed() {
        let meter = TransferIOMeter(destinationCount: 2)
        #expect(meter.record(destination: 5, phase: .writing, bytes: 100, duration: 1, now: 1) == nil)
        #expect(meter.record(destination: 0, phase: .writing, bytes: 0, duration: 1, now: 1) == nil)
        #expect(meter.record(destination: 0, phase: .writing, bytes: 100, duration: -1, now: 1) == nil)
        let snapshot = meter.finalSnapshot(now: 1)
        #expect(snapshot.destinations.allSatisfy { $0.writtenBytes == 0 && $0.writeBytesPerSecond == nil })
    }

    @Test func throttledUIUpdatesStillCountEverySuccessfulChunk() throws {
        let meter = TransferIOMeter(destinationCount: 1)
        let first = try #require(meter.record(destination: 0, phase: .writing,
                                              bytes: 100, duration: 0.1, now: 10))
        #expect(meter.record(destination: 0, phase: .writing,
                             bytes: 200, duration: 0.1, now: 10.1) == nil)
        let final = meter.finalSnapshot(now: 10.1)
        #expect(final.sequence > first.sequence)
        #expect(final.destinations[0].writtenBytes == 300)
        #expect(abs((final.destinations[0].writeBytesPerSecond ?? 0) - 1_500) < 1)
    }

    @Test func sourceReuseHashWorkDoesNotCountAsDestinationReadback() throws {
        let meter = TransferIOMeter(destinationCount: 1)
        for phase in [TransferIOPhase.sourceHashing, .sourceReuseHashing, .sourceReuseComparing] {
            #expect(meter.record(destination: 0, phase: phase, bytes: 10_000,
                                 duration: 0.1, now: 10) == nil)
        }
        _ = meter.record(destination: 0, phase: .destinationReuseComparing,
                         bytes: 128, duration: 0.2, now: 10)
        _ = meter.record(destination: 0, phase: .destinationReuseComparing,
                         bytes: 256, duration: 0.2, now: 10.3)
        let snapshot = meter.finalSnapshot(now: 10.3)
        #expect(snapshot.destinations[0].readbackBytes == 384)
        #expect((snapshot.destinations[0].readbackBytesPerSecond ?? 0) > 0)
    }

    @Test func overlappingCallsCountConcurrentBytesOverOneActiveInterval() {
        let meter = TransferIOMeter(destinationCount: 1)
        let chunk = 4 * 1024 * 1024
        _ = meter.record(destination: 0, phase: .writing, bytes: chunk, duration: 1, now: 10)
        _ = meter.record(destination: 0, phase: .writing, bytes: chunk, duration: 1, now: 10)
        let snapshot = meter.finalSnapshot(now: 10)
        #expect(snapshot.destinations[0].writtenBytes == Int64(chunk * 2))
        #expect(abs((snapshot.destinations[0].writeBytesPerSecond ?? 0) - Double(chunk * 2)) < 1)
        #expect(snapshot.destinations[0].writeRateWindowStartUptime == 9)
    }

    @Test func sustainedFastCallsStillProduceARate() {
        let meter = TransferIOMeter(destinationCount: 1)
        for index in 0..<64 {
            _ = meter.record(destination: 0, phase: .writing,
                             bytes: 4 * 1024 * 1024, duration: 0.0005,
                             now: 10 + Double(index + 1) * 0.0005)
        }
        let snapshot = meter.finalSnapshot(now: 10.032)
        #expect(snapshot.destinations[0].writtenBytes == 64 * 4 * 1024 * 1024)
        #expect((snapshot.destinations[0].writeBytesPerSecond ?? 0) > 0)
    }
}
