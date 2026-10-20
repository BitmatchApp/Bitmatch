import Foundation

/// Disk Arbitration needs a mount root, even when a selected folder is several
/// levels below it. Read only that selection's volume fact; never discover or
/// enumerate other mounted volumes. Both identity and connection lookup use
/// this adapter before calling DADiskCreateFromVolumePath.
enum SelectedVolumeDiskResolver {
    static func disk<Disk>(
        for selectedURL: URL,
        readVolumeRoot: (URL) -> URL?,
        makeDisk: (URL) -> Disk?,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Disk? {
        guard selectedURL.isFileURL, !isCancelled(),
              let volumeRoot = readVolumeRoot(selectedURL), volumeRoot.isFileURL,
              !isCancelled() else { return nil }
        return makeDisk(volumeRoot)
    }
}
