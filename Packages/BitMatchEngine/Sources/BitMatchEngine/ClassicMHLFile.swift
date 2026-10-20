import Darwin
import Foundation

/// Read-only descriptor traversal for classic evidence and the files it names.
/// Hold the ancestor descriptors until validation, so moving/replacing a parent
/// cannot make a read from a detached directory look like a check of its name.
final class ClassicMHLFile {
    struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = UInt64(info.st_ino)
            size = info.st_size
            modificationSeconds = Int64(info.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changeSeconds = Int64(info.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    private struct Link {
        let parent: Int32
        let name: String
        let descriptor: Int32
        let device: Int32
        let inode: UInt64
    }

    let handle: FileHandle
    let identity: Identity
    private let ancestors: [Int32]
    private let links: [Link]
    private let leafName: String

    init(url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var parts = url.standardizedFileURL.pathComponents
        // Match the copy engine's fixed macOS aliases. User-controlled links
        // are never resolved or followed by the traversal below.
        if parts.count > 1, ["var", "tmp", "etc"].contains(parts[1]) {
            parts = ["/", "private"] + Array(parts.dropFirst())
        }
        guard parts.first == "/", parts.count > 1, parts.count <= 256 else {
            throw SavedChecksumCheck.CheckError.unreadableEvidence
        }
        let root = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var opened = [root]
        var links: [Link] = []
        var leaf: Int32 = -1
        do {
            for name in parts.dropFirst().dropLast() {
                try Task.checkCancellation()
                guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else {
                    throw SavedChecksumCheck.CheckError.unreadableEvidence
                }
                let parent = opened[opened.count - 1]
                let child = openat(parent, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
                opened.append(child)
                var info = stat()
                guard fstat(child, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw SavedChecksumCheck.CheckError.unreadableEvidence
                }
                links.append(Link(parent: parent, name: name, descriptor: child,
                                  device: info.st_dev, inode: UInt64(info.st_ino)))
            }
            let name = parts[parts.count - 1]
            guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else {
                throw SavedChecksumCheck.CheckError.unreadableEvidence
            }
            leaf = openat(opened[opened.count - 1], name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard leaf >= 0 else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
            var info = stat()
            guard fstat(leaf, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
                throw SavedChecksumCheck.CheckError.unreadableEvidence
            }
            self.handle = FileHandle(fileDescriptor: leaf, closeOnDealloc: true)
            self.identity = Identity(info)
            self.ancestors = opened
            self.links = links
            self.leafName = name
        } catch {
            if leaf >= 0 { Darwin.close(leaf) }
            for descriptor in opened.reversed() { Darwin.close(descriptor) }
            throw error
        }
    }

    deinit {
        try? handle.close()
        for descriptor in ancestors.reversed() { Darwin.close(descriptor) }
    }

    func validateUnchanged() throws {
        try Task.checkCancellation()
        for link in links {
            var named = stat()
            var pinned = stat()
            guard fstat(link.descriptor, &pinned) == 0,
                  fstatat(link.parent, link.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  (named.st_mode & S_IFMT) == S_IFDIR,
                  named.st_dev == link.device, UInt64(named.st_ino) == link.inode,
                  pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino else {
                throw SavedChecksumCheck.CheckError.unreadableEvidence
            }
        }
        var current = stat()
        var named = stat()
        guard fstat(handle.fileDescriptor, &current) == 0,
              fstatat(ancestors[ancestors.count - 1], leafName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFREG,
              Identity(current) == identity, Identity(named) == identity else {
            throw SavedChecksumCheck.CheckError.unreadableEvidence
        }
    }

    func boundedData(maxBytes: Int) throws -> Data {
        guard identity.size <= maxBytes else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool { () throws -> Bool in
                let chunk = try handle.read(upToCount: min(64 * 1024, maxBytes - data.count) + 1) ?? Data()
                guard chunk.count <= maxBytes - data.count else {
                    throw SavedChecksumCheck.CheckError.unreadableEvidence
                }
                data.append(chunk)
                return chunk.isEmpty
            }
            if finished { break }
        }
        guard data.count == identity.size else { throw SavedChecksumCheck.CheckError.unreadableEvidence }
        try validateUnchanged()
        return data
    }

    static func currentIdentity(at url: URL) throws -> Identity {
        let file = try ClassicMHLFile(url: url)
        try file.validateUnchanged()
        return file.identity
    }
}
