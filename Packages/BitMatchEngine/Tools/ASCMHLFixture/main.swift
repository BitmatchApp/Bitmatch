import Foundation
import CryptoKit
import BitMatchEngine

/// A disposable interoperability sample for Scripts/ascmhl/validate_reference.sh.
@main
struct Main {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ASCMHLFixture", code: 64,
                          userInfo: [NSLocalizedDescriptionKey: "Pass a new fixture directory."])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Camera A"), withIntermediateDirectories: true)
        let data = Data("BitMatch interoperability test\n".utf8)
        let path = "Camera A/clip & café.txt"
        try data.write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [.init(relativePath: path, size: Int64(data.count), expectedSHA256: sha)],
            startTime: Date(), toolVersion: "compatibility-fixture")
        print(url.path)
    }
}
