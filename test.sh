#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
JOB=${1:-mac-test}
# Keep app-hosted tests and Sparkle's loader outside protected Desktop folders.
# A stable per-checkout key avoids mixing parallel worktrees' build products.
CHECKOUT_CACHE_KEY=$(printf '%s' "$ROOT" | shasum -a 256 | cut -c 1-16)
DERIVED_DATA_ROOT=${DERIVED_DATA_ROOT:-"/private/tmp/bitmatch-local-tests-$(id -u)/$CHECKOUT_CACHE_KEY"}

clear_inherited_stress_controls() {
  local name control cleared=false
  # Inspect exported names only: fixture paths and other values stay private.
  while IFS= read -r name; do
    control=${name#TEST_RUNNER_}
    case "$control" in
      BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS|BITMATCH_PDF_EDGE_ARTIFACTS|BITMATCH_PREVIEW_PDF_OUTPUT|BITMATCH_REPORT_PDF_ARTIFACTS|BITMATCH_MATRIX_ARTIFACTS|BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR)
        # Keep the documented snapshot workflow and output-only routing.
        ;;
      BITMATCH_*)
        unset "$name"
        cleared=true
        ;;
    esac
  done < <(compgen -e)
  if [[ "$cleared" == true ]]; then
    echo 'Ordinary test job: cleared inherited BitMatch probe controls; use the dedicated stress/hardware runners for opt-in workloads.' >&2
  fi
}

run_xcodebuild() {
  local name=$1
  shift
  xcodebuild -project "$ROOT/BitMatch.xcodeproj" \
    -derivedDataPath "$DERIVED_DATA_ROOT/$name" \
    CODE_SIGNING_ALLOWED=NO "$@"
}

case "$JOB" in
  mac-test)
    clear_inherited_stress_controls
    run_xcodebuild mac-test test -scheme BitMatch -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:BitMatchTests
    ;;
  mac-build)
    run_xcodebuild mac-build build -scheme BitMatch -configuration Debug -destination 'platform=macOS'
    ;;
  ipad-build)
    run_xcodebuild ipad-build build -scheme BitMatch-iPad -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'
    ;;
  ipad-test)
    : "${IOS_SIMULATOR_DESTINATION:?Set IOS_SIMULATOR_DESTINATION, for example platform=iOS Simulator,name=iPad (A16)}"
    clear_inherited_stress_controls
    run_xcodebuild ipad-test test -scheme BitMatch-iPad -destination "$IOS_SIMULATOR_DESTINATION" -parallel-testing-enabled NO -only-testing:BitMatch-iPadTests
    ;;
  engine-test)
    clear_inherited_stress_controls
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
