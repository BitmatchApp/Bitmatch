import Foundation
import CoreGraphics
import Testing
@testable import BitMatch

/// One ProRes frame to one fitted image via VideoToolbox. Design:
/// docs/superpowers/specs/2026-11-20-mxf-prores-previews-design.md
struct ProResFrameDecoderTests {
    private let lt = MXFFixtures.frame(MXFFixtures.orange64By64lt, length: MXFFixtures.orange64By64ltLength)
    private let hq = MXFFixtures.frame(MXFFixtures.orange64By64hq, length: MXFFixtures.orange64By64hqLength)
    private let tall = MXFFixtures.frame(MXFFixtures.orange64By48lt, length: MXFFixtures.orange64By48ltLength)

    @Test func decodesTheOrangeFixtureFrameToAFittedImage() throws {
        let image = try #require(ProResFrameDecoder.image(frame: lt, maximumSize: CGSize(width: 256, height: 144)))
        #expect(image.width == image.height)
        #expect(image.width <= 144)
        let (r, g, b) = try centerPixel(image)
        #expect(r > 200); #expect(g >= 80 && g <= 200); #expect(b < 80)
    }

    @Test func keepsAspectAndNeverUpscales() throws {
        let fitted = try #require(ProResFrameDecoder.image(frame: tall, maximumSize: CGSize(width: 256, height: 144)))
        #expect(fitted.width == 64 && fitted.height == 48, "a 64×48 frame is not upscaled")
        let small = try #require(ProResFrameDecoder.image(frame: tall, maximumSize: CGSize(width: 32, height: 32)))
        #expect(small.width == 32 && small.height == 24)
    }

    @Test func decodesHQAndLTUnderTheSameFormat() throws {
        #expect(ProResFrameDecoder.image(frame: hq, maximumSize: CGSize(width: 256, height: 144)) != nil)
        #expect(try #require(ProResFrameDecoder.header(of: hq)).is444 == false)
        #expect(try #require(ProResFrameDecoder.header(of: lt)).is444 == false)
    }

    @Test func rejectsBeforeDecoding() throws {
        for count in 1 ..< 32 { #expect(ProResFrameDecoder.header(of: lt.prefix(count)) == nil, "prefix \(count)") }
        #expect(ProResFrameDecoder.header(of: patched(lt, at: 4, [0x69, 0x63, 0x70, 0x67])) == nil, "tag icpg")
        #expect(ProResFrameDecoder.header(of: patched(lt, at: 0, be32(lt.count + 1))) == nil, "frame size past the data")
        #expect(ProResFrameDecoder.header(of: patched(lt, at: 8, [0x00, 0x0A])) == nil, "header size 10")
        #expect(ProResFrameDecoder.header(of: patched(lt, at: 16, [0x40, 0x00, 0x40, 0x00])) == nil, "16384×16384")
        #expect(ProResFrameDecoder.header(of: patched(lt, at: 16, [0x1F, 0x40, 0x1F, 0x40])) == nil, "8000×8000 is 64 MP")
        let alexa65 = try #require(ProResFrameDecoder.header(of: patched(lt, at: 16, [0x19, 0xA0, 0x0C, 0x1C])))
        #expect(alexa65.width == 6560 && alexa65.height == 3100)
        #expect(ProResFrameDecoder.image(frame: patched(lt, at: 16, [0x1F, 0x40, 0x1F, 0x40]), maximumSize: CGSize(width: 256, height: 144)) == nil)
    }

    @Test func emptyDataIsNil() {
        #expect(ProResFrameDecoder.header(of: Data()) == nil)
        #expect(ProResFrameDecoder.image(frame: Data(), maximumSize: CGSize(width: 256, height: 144)) == nil)
    }

    // MARK: Helpers

    private func patched(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
        var copy = data
        copy.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
        return copy
    }

    private func be32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) } }

    private func centerPixel(_ image: CGImage) throws -> (UInt8, UInt8, UInt8) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let index = ((height / 2) * width + width / 2) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }
}
