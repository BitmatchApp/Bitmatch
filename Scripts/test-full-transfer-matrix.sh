#!/usr/bin/env bash
# 800 option/filesystem combinations, each followed by a repeat/reuse run.
# MATRIX_FOCUS=all also checks naming, projects, evidence, collisions and the
# FAT32 size limit in the same image pool. Use evidence for app/history only.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_NAME=testFullSyntheticFilesystemMatrix
if [[ "${MATRIX_FOCUS:-full}" == rename ]]; then TEST_NAME=testCameraRenameFilesystemMatrix; fi
if [[ "${MATRIX_FOCUS:-full}" == collision ]]; then TEST_NAME=testCaseCollisionsAcrossRealFilesystems; fi
if [[ "${MATRIX_FOCUS:-full}" == features ]]; then TEST_NAME=testProjectAndReportFilesystemMatrix; fi
if [[ "${MATRIX_FOCUS:-full}" == limits ]]; then TEST_NAME=testFAT32LargeFileLimitKeepsOtherBackupVerified; fi
IMAGE_SIZE=3g
if [[ "${MATRIX_FOCUS:-full}" == limits || "${MATRIX_FOCUS:-full}" == all ]]; then IMAGE_SIZE=6g; fi
PAIR=$(mktemp -d /tmp/bitmatch-full-matrix.XXXXXX)
touch "$PAIR/.bitmatch-matrix-owned"
MOUNTS=()
cleanup() {
  local status=$?
  local busy=0
  for mount in "${MOUNTS[@]-}"; do
    [[ -n "$mount" ]] || continue
    hdiutil detach -quiet "$mount" || busy=1
  done
  if [[ "$busy" == 0 && -f "$PAIR/.bitmatch-matrix-owned" ]]; then
    rm -rf "$PAIR"
  else
    echo "Disposable images retained for inspection: $PAIR" >&2
    if [[ "$status" == 0 ]]; then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT
for role in source destination; do
 for item in 'apfs:APFS' 'hfs:JHFS+' 'exfat:ExFAT' 'apfsx:Case-sensitive APFS' 'fat:MS-DOS FAT32'; do
  name="$role-${item%%:*}"; fs=${item#*:}
  mkdir "$PAIR/$name"
  hdiutil create -size "$IMAGE_SIZE" -type SPARSE -fs "$fs" -volname "BM_${item%%:*}" -o "$PAIR/$name.sparseimage"
  MOUNTS+=("$PAIR/$name")
  hdiutil attach -quiet -nobrowse -mountpoint "$PAIR/$name" "$PAIR/$name.sparseimage"
 done
done
TESTS=("-only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests/$TEST_NAME")
EXPECTED_TESTS=1
if [[ "${MATRIX_FOCUS:-full}" == evidence ]]; then
  TESTS=("-only-testing:BitMatchTests/MountedWorkflowEvidenceMatrixTests")
  EXPECTED_TESTS=3
elif [[ "${MATRIX_FOCUS:-full}" == all ]]; then
  EXPECTED_TESTS=8
  TESTS=(
    "-only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests/testFullSyntheticFilesystemMatrix"
    "-only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests/testCameraRenameFilesystemMatrix"
    "-only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests/testProjectAndReportFilesystemMatrix"
    "-only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests/testCaseCollisionsAcrossRealFilesystems"
    "-only-testing:BitMatchTests/CopyVerifyExecutorIntegrityTests/testFAT32LargeFileLimitKeepsOtherBackupVerified"
    "-only-testing:BitMatchTests/MountedWorkflowEvidenceMatrixTests"
  )
fi
if [[ -n "${MATRIX_KEY:-}" ]]; then export TEST_RUNNER_BITMATCH_MATRIX_KEY="$MATRIX_KEY"; fi
TEST_RUNNER_BITMATCH_MATRIX_TRACE="${MATRIX_TRACE:-0}" \
TEST_RUNNER_BITMATCH_MATRIX_ROOT="$PAIR" \
xcodebuild -project "$ROOT/BitMatch.xcodeproj" -derivedDataPath "${MATRIX_DERIVED_DATA:-$ROOT/.derived-data/mac-test}" \
 CODE_SIGNING_ALLOWED=NO test -scheme BitMatch -destination 'platform=macOS' \
 -jobs 4 -parallel-testing-enabled NO \
 "${TESTS[@]}" | awk -v expected="$EXPECTED_TESTS" '
 { print }
 /^Test Case .* passed \(/ { passed++ }
 END {
   if (passed != expected) {
     printf "Matrix execution incomplete: expected %d passing XCTest cases, observed %d.\n", expected, passed > "/dev/stderr"
     exit 1
   }
   printf "MATRIX_EXECUTION_RECEIPT expectedTests=%d passedTests=%d\n", expected, passed
 }'
