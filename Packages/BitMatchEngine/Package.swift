// swift-tools-version: 6.0
// BitMatchEngine: copy, verify, compare, evidence and the safety rules
// behind Promises 1-3 (docs/THESIS.md). No UI; the Mac, iPad and iPhone
// apps are clients of it.
import PackageDescription

let package = Package(
    name: "BitMatchEngine",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BitMatchEngine", targets: ["BitMatchEngine"]),
    ],
    targets: [
        .target(
            name: "BitMatchEngine",
            linkerSettings: [
                .linkedFramework("DiskArbitration", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "BitMatchEngineTests",
            dependencies: ["BitMatchEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
