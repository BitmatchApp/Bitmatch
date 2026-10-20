# Translated x86_64 engine validation — October 19, 2026

The Release engine at `4106a48a` was cross-compiled as an x86_64-only test bundle and executed through the already installed Rosetta translation on an Apple Silicon Mac running macOS 27.0.1, using Xcode 27.1. This is translated engine coverage, not execution on a physical Intel Mac or an older macOS release. The universal Mac app build is separate evidence.

| Framework | Scheduled | Passed | Skipped | Failures |
| --- | ---: | ---: | ---: | ---: |
| XCTest | 223 | 186 | 37 | 0 |
| Swift Testing | 219 declarations in 39 suites | 213 | 6 | 0 |

The active Swift Testing declarations executed 333 invocations: 153 parameterized cases and 180 ordinary tests. Hardware, large-memory, mounted-image, soak and benchmark opt-ins were unset. No app host or physical-drive workload ran.

Xcode's Swift compiler and stock SwiftPM testing helpers were ARM-only; forcing those helpers to x86_64 failed before discovery. The native compiler built the x86_64 tests with Release optimization and testable imports. XCTest used Xcode's universal host with x86_64 explicitly selected. Swift Testing used a private x86_64 build of the [minimal upstream SwiftPM bundle loader](https://github.com/swiftlang/swift-package-manager/blob/232c7e26344962870cb0d19ae8b7399f584c6c32/Sources/swiftpm-testing-helper/Entrypoint.swift), licensed under Apache 2.0 with the Swift Runtime Library Exception. Its logic was unchanged; Foundation linkage and Xcode framework search paths matched the installed test environment.

The unsigned private loader initially produced 13 bookmark-setup failures with Cocoa error 256. Giving only that disposable loader an explicit ad-hoc signing identity, with no added entitlements, cleared those failures in the complete rerun. Product code and test assertions were unchanged. The failed control is retained separately from the passing result; it is not hidden as a skip.

Architecture checks confirmed that both the bundle and private loader contained only x86_64. Temporary binaries and build caches were removed after collecting compact counts, logs, signing/provenance metadata and architecture receipts. These results do not establish native Intel performance, macOS 15.0 runtime compatibility, physical hardware reliability or the cause of an open field report.
