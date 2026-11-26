import Foundation

/// Builders for Finder `.DS_Store` fixtures shared by the Finder metadata tests.
enum FinderMetadataFixtures {
    /// A buddy-allocator header: 00 00 00 01, "Bud1", offset, root size, offset
    /// again, 16 zero bytes, zero-padded to `size` bytes. The defaults describe a
    /// consistent header (offset 0x800, size 0x800).
    static func bud1(size: Int, offset: UInt32 = 0x800, repeatedOffset: UInt32? = nil, rootSize: UInt32 = 0x800) -> Data {
        var bytes: [UInt8] = [0, 0, 0, 1] + Array("Bud1".utf8)
        func put(_ value: UInt32) { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) } }
        put(offset); put(rootSize); put(repeatedOffset ?? offset)
        bytes += [UInt8](repeating: 0, count: 16)
        if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
        return Data(bytes.prefix(max(size, 0)))
    }

    static func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-finder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
