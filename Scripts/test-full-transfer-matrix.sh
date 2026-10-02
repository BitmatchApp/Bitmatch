#!/usr/bin/env bash
# 512 option/filesystem combinations, each followed by a repeat/reuse run.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_NAME=testFullSyntheticFilesystemMatrix
if [[ "${MATRIX_FOCUS:-full}" == collision ]]; then TEST_NAME=testCaseCollisionsAcrossRealFilesystems; fi
PAIR=$(mktemp -d /tmp/bitmatch-full-matrix.XXXXXX)
touch "$PAIR/.bitmatch-matrix-owned"
MOUNTS=()
cleanup() {
  local busy=0
  for mount in "${MOUNTS[@]}"; do hdiutil detach -quiet "$mount" || busy=1; done
  if [[ "$busy" == 0 ]]; then rm -rf "$PAIR"; else echo "Busy disposable images retained: $PAIR" >&2; fi
}
trap cleanup EXIT
for role in source destination; do
 for item in 'apfs:APFS' 'hfs:JHFS+' 'exfat:ExFAT' 'apfsx:Case-sensitive APFS'; do
  name="$role-${item%%:*}"; fs=${item#*:}
  mkdir "$PAIR/$name"
  hdiutil create -size 3g -type SPARSE -fs "$fs" -volname "BM_${item%%:*}" -o "$PAIR/$name.sparseimage"
  hdiutil attach -quiet -nobrowse -mountpoint "$PAIR/$name" "$PAIR/$name.sparseimage"
  MOUNTS+=("$PAIR/$name")
 done
done
if [[ -n "${MATRIX_KEY:-}" ]]; then export TEST_RUNNER_BITMATCH_MATRIX_KEY="$MATRIX_KEY"; fi
TEST_RUNNER_BITMATCH_MATRIX_ROOT="$PAIR" \
xcodebuild -project "$ROOT/BitMatch.xcodeproj" -derivedDataPath "${MATRIX_DERIVED_DATA:-$ROOT/.derived-data/mac-test}" \
 CODE_SIGNING_ALLOWED=NO test -scheme BitMatch -destination 'platform=macOS' \
 -parallel-testing-enabled NO \
 -only-testing:"BitMatchTests/CopyVerifyExecutorIntegrityTests/$TEST_NAME"
