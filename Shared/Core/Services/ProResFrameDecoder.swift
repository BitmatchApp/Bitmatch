// ProResFrameDecoder.swift - One ProRes frame to one preview-sized image.
import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import VideoToolbox

/// Decodes a single ProRes frame (as found inside an MXF wrapper) with
/// VideoToolbox's ProRes decoder. Report decoration only: every failure is
/// nil, and nothing here touches transfer evidence. Design:
/// docs/superpowers/specs/2026-11-20-mxf-prores-previews-design.md
enum ProResFrameDecoder {
    static let maximumPixels = 40_000_000
    static let maximumSide = 8192
    static let minimumSide = 16
    static let minimumFrameSize = 32
    static let minimumHeaderSize = 20

    struct Header: Equatable {
        let frameSize: Int
        let width: Int
        let height: Int
        let is444: Bool
    }

    /// The frame's own header, validated before any decoder exists. The
    /// pixel cap is what bounds memory: the compressed frame is small, the
    /// decoded one is not.
    static func header(of frame: Data) -> Header? {
        guard frame.count >= minimumFrameSize else { return nil }
        let bytes = [UInt8](frame.prefix(24))
        let frameSize = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard frameSize >= minimumFrameSize, frameSize <= frame.count else { return nil }
        guard bytes[4] == 0x69, bytes[5] == 0x63, bytes[6] == 0x70, bytes[7] == 0x66 else { return nil }   // "icpf"
        let headerSize = Int(bytes[8]) << 8 | Int(bytes[9])
        guard headerSize >= minimumHeaderSize, 8 + headerSize <= frameSize else { return nil }
        let width = Int(bytes[16]) << 8 | Int(bytes[17])
        let height = Int(bytes[18]) << 8 | Int(bytes[19])
        guard width >= minimumSide, height >= minimumSide, width <= maximumSide, height <= maximumSide,
              width * height <= maximumPixels else { return nil }
        let chroma = (bytes[20] >> 6) & 0x3   // 2 = 4:2:2, 3 = 4:4:4
        guard chroma == 2 || chroma == 3 else { return nil }
        return Header(frameSize: frameSize, width: width, height: height, is444: chroma == 3)
    }

    /// The decoded frame fitted inside `maximumSize`, aspect kept, never
    /// upscaled. The decoder is asked for that output size directly so the
    /// full-size frame is not materialized here.
    static func image(frame: Data, maximumSize: CGSize) -> CGImage? {
        guard let header = header(of: frame) else { return nil }
        let scale = min(1, min(maximumSize.width / CGFloat(header.width), maximumSize.height / CGFloat(header.height)))
        let outputWidth = max(1, Int((CGFloat(header.width) * scale).rounded()))
        let outputHeight = max(1, Int((CGFloat(header.height) * scale).rounded()))
        return autoreleasepool { () -> CGImage? in
            let codec: CMVideoCodecType = header.is444 ? kCMVideoCodecType_AppleProRes4444 : kCMVideoCodecType_AppleProRes422HQ
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec, width: Int32(header.width),
                                                 height: Int32(header.height), extensions: nil, formatDescriptionOut: &format) == noErr,
                  let format else { return nil }
            // The block buffer owns a copy of the frame bytes for the sample's lifetime.
            let length = header.frameSize
            guard let memory = malloc(length) else { return nil }
            frame.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: length)
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: memory, blockLength: length,
                                                     blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else {
                free(memory)
                return nil
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var size = length
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: outputWidth,
                kCVPixelBufferHeightKey: outputHeight,
            ]
            var session: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                               imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &session) == noErr, let session else { return nil }
            defer { VTDecompressionSessionInvalidate(session) }
            var decoded: CVPixelBuffer?
            // Empty flags: synchronous, no temporal processing, so the handler runs before this returns.
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
                if status == noErr { decoded = buffer }
            }
            guard status == noErr, VTDecompressionSessionWaitForAsynchronousFrames(session) == noErr, let decoded else { return nil }
            let ciImage = CIImage(cvPixelBuffer: decoded)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let full = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            if full.width == outputWidth && full.height == outputHeight { return full }
            // A decoder that ignored the size request: fit it here.
            return downscale(full, width: outputWidth, height: outputHeight)
        }
    }

    private static func downscale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
