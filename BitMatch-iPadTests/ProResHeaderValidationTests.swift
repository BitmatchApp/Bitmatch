import Foundation
import Testing
@testable import BitMatch_iPad

/// The parts of the decoder that need no decoder: header validation runs on
/// the simulator even though frame decoding cannot.
struct ProResHeaderValidationTests {
    @Test func headerValidationNeedsNoDecoder() throws {
        let lt = MXFFixtures.frame(MXFFixtures.orange64By64lt, length: MXFFixtures.orange64By64ltLength)
        let header = try #require(ProResFrameDecoder.header(of: lt))
        #expect(header.width == 64 && header.height == 64 && header.is444 == false)
        for count in 1 ..< 32 { #expect(ProResFrameDecoder.header(of: lt.prefix(count)) == nil) }
        #expect(ProResFrameDecoder.header(of: Data()) == nil)
    }

    @Test func reportsWhetherADecoderExists() {
        let probe = ProResFrameDecoder.decoderAvailable
        #if targetEnvironment(simulator)
        #expect(probe.available == false, "the simulator is expected to have no ProRes decoder; if it does, drop this expectation")
        #else
        #expect(probe.available == true)
        #endif
    }
}
