#!/usr/bin/env bash
# Disposable real-driver reproduction. Provision mounts before launching the app test host.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAIR=$(mktemp -d /tmp/bitmatch-issue10-pair.XXXXXX)
SOURCE="$PAIR/source"
DESTINATION="$PAIR/destination"
SOURCE_ATTACHED=0
DESTINATION_ATTACHED=0
cleanup() {
  local busy=0
  if [[ $DESTINATION_ATTACHED == 1 ]]; then hdiutil detach -quiet "$DESTINATION" || busy=1; fi
  if [[ $SOURCE_ATTACHED == 1 ]]; then hdiutil detach -quiet "$SOURCE" || busy=1; fi
  if [[ $busy == 0 ]]; then rm -rf "$PAIR"; else echo "Busy disposable images retained: $PAIR" >&2; fi
}
trap cleanup EXIT
mkdir "$SOURCE" "$DESTINATION"
hdiutil create -size 3g -type SPARSE -fs JHFS+ -volname BM10_SRC -o "$PAIR/source.sparseimage"
hdiutil create -size 3g -type SPARSE -fs ExFAT -volname BM10_DST -o "$PAIR/destination.sparseimage"
hdiutil attach -quiet -nobrowse -mountpoint "$SOURCE" "$PAIR/source.sparseimage"
SOURCE_ATTACHED=1
hdiutil attach -quiet -nobrowse -mountpoint "$DESTINATION" "$PAIR/destination.sparseimage"
DESTINATION_ATTACHED=1
# Xcode forwards TEST_RUNNER_ variables to the host after removing the prefix.
TEST_RUNNER_BITMATCH_ISSUE10_SOURCE="$SOURCE" \
TEST_RUNNER_BITMATCH_ISSUE10_DESTINATION="$DESTINATION" \
xcodebuild -project "$ROOT/BitMatch.xcodeproj" -derivedDataPath "$ROOT/.derived-data/mac-test" \
 CODE_SIGNING_ALLOWED=NO test -scheme BitMatch -destination 'platform=macOS' \
 -only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests
