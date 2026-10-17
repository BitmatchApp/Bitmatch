#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
JOB=${1:-mac-test}
DERIVED_DATA_ROOT=${DERIVED_DATA_ROOT:-"$ROOT/.derived-data"}

run_xcodebuild() {
  local name=$1
  shift
  xcodebuild -project "$ROOT/BitMatch.xcodeproj" \
    -derivedDataPath "$DERIVED_DATA_ROOT/$name" \
    CODE_SIGNING_ALLOWED=NO "$@"
}

case "$JOB" in
  mac-test)
    run_xcodebuild mac-test test -scheme BitMatch -destination 'platform=macOS' -only-testing:BitMatchTests
    ;;
  mac-build)
    run_xcodebuild mac-build build -scheme BitMatch -configuration Debug -destination 'platform=macOS'
    ;;
  ipad-build)
    run_xcodebuild ipad-build build -scheme BitMatch-iPad -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
    ;;
  ipad-test)
    : "${IOS_SIMULATOR_DESTINATION:?Set IOS_SIMULATOR_DESTINATION, for example platform=iOS Simulator,name=iPad (A16)}"
    run_xcodebuild ipad-test test -scheme BitMatch-iPad -destination "$IOS_SIMULATOR_DESTINATION" -only-testing:BitMatch-iPadTests
    ;;
  engine-test)
    # Keep independent disk fixtures from racing short setup deadlines. Each
    # test still exercises its own concurrent copy/verify workers.
    # Xcode 27 can choose an arm64e host for a mixed SwiftPM test run and fail
    # to load the package's arm64-only XCTest bundle, while Swift Testing still
    # runs. Run each test framework explicitly so neither can be omitted.
    run_engine_tests() {
      if [[ "$(uname -m)" == arm64 ]]; then
        arch -arm64 swift test --package-path "$ROOT/Packages/BitMatchEngine" --build-system native --no-parallel "$@"
      else
        swift test --package-path "$ROOT/Packages/BitMatchEngine" --build-system native --no-parallel "$@"
      fi
    }
    run_engine_tests --disable-swift-testing
    run_engine_tests --disable-xctest
    ;;
  release-builds)
    run_xcodebuild mac-release build -scheme BitMatch -configuration Release -destination 'platform=macOS'
    run_xcodebuild ipad-release build -scheme BitMatch-iPad -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
    ;;
  *)
    echo "Usage: $0 {engine-test|mac-test|mac-build|ipad-build|ipad-test|release-builds}" >&2
    exit 64
    ;;
esac
