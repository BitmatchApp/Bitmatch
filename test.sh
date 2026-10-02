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
    # Match the Apple Silicon test host to the package's arm64 bundle. Newer
    # Xcode hosts may otherwise choose arm64e and refuse to load XCTest.
    if [[ "$(uname -m)" == arm64 ]]; then
      arch -arm64 swift test --package-path "$ROOT/Packages/BitMatchEngine" --build-system native
    else
      swift test --package-path "$ROOT/Packages/BitMatchEngine" --build-system native
    fi
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
