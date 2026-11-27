import Foundation

/// Builders for Finder `.DS_Store` fixtures shared by the Finder metadata tests.
enum FinderMetadataFixtures {
    /// A buddy-allocator header: 00 00 00 01, "Bud1", offset, root size, offset
    /// again, 16 zero bytes, zero-padded to `size` bytes. The defaults describe a
    /// consistent header (offset 0x800, size 0x800). With `rootMarker`, the root
    /// block the header points to (at 4 + offset) holds the one `DSDB`
    /// directory entry and an allocated B-tree header, when they fit in `size`.
    static func bud1(size: Int, offset: UInt32 = 0x800, repeatedOffset: UInt32? = nil, rootSize: UInt32 = 0x800,
                     rootMarker: Bool = true) -> Data {
        var bytes: [UInt8] = [0, 0, 0, 1] + Array("Bud1".utf8)
        func put(_ value: UInt32) { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) } }
        put(offset); put(rootSize); put(repeatedOffset ?? offset)
        bytes += [UInt8](repeating: 0, count: 16)
        if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
        // Finder stores a reserved word after the count, then a table padded
        // to 256 block addresses, followed by its directory.
        let root = Int(offset) + 4
        let entry: [UInt8] = [0, 0, 0, 2, 0, 0, 0, 0]
            + [0, 0, 0x10, 0x05, 0, 0, 0x12, 0x05] + [UInt8](repeating: 0, count: 254 * 4)
            + [0, 0, 0, 1, 4] + Array("DSDB".utf8) + [0, 0, 0, 0]
        if rootMarker, root >= 36, root + entry.count <= min(bytes.count, root + Int(rootSize)) {
            bytes.replaceSubrange(root..<root + entry.count, with: entry)
        }
        // DSDB block 0 resolves to offset 0x1000, size 32; root node 1.
        let tree = 4 + 0x1000
        if rootMarker, tree + 16 <= bytes.count {
            bytes.replaceSubrange(tree..<tree + 16, with: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1])
        }
        return Data(bytes.prefix(max(size, 0)))
    }

    static func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-finder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
