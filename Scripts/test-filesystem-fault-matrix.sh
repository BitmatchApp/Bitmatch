#!/usr/bin/env bash
# Run the fault/reuse/safety suites with fixtures on each real filesystem.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/harness_evidence.sh"
PAIR=$(mktemp -d /private/tmp/bitmatch-fault-matrix.XXXXXX)
touch "$PAIR/.bitmatch-fault-matrix-owned"
initialize_evidence filesystem-fault-matrix
LOG_DIR="$EVIDENCE"
MOUNTS=()
cleanup() {
 local status=$?
 trap - EXIT INT TERM
 local busy=0
 mount > "$PAIR/mounts-before-cleanup.txt" || busy=1
 for mount in "${MOUNTS[@]}"; do
  if grep -F -- " on $mount (" "$PAIR/mounts-before-cleanup.txt" >/dev/null; then
   hdiutil detach -quiet "$mount" || busy=1
  fi
 done
 mount > "$PAIR/mounts-after-cleanup.txt" || busy=1
 if grep -F -- " on $PAIR/" "$PAIR/mounts-after-cleanup.txt" >/dev/null; then busy=1; fi
 if [[ "$busy" == 0 && -f "$PAIR/.bitmatch-fault-matrix-owned" ]]; then
  rm -rf "$PAIR" || status=1
 else
  echo "Busy or unmarked disposable images retained: $PAIR" >&2
  status=1
 fi
 finish_evidence "$status" || status=1
 exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SWIFT=(swift)
if [[ "$(uname -m)" == arm64 ]]; then SWIFT=(arch -arm64 swift); fi
"${SWIFT[@]}" build --build-tests --jobs 4 --package-path "$ROOT/Packages/BitMatchEngine" \
 --scratch-path "$PAIR/build" > "$LOG_DIR/build.log" 2>&1
failed=0
for item in 'apfs:APFS' 'hfs:Journaled HFS+' 'exfat:ExFAT' 'apfsx:Case-sensitive APFS' 'hfsx:Case-sensitive Journaled HFS+' 'fat:MS-DOS FAT32'; do
 name=${item%%:*}; fs=${item#*:}
 mkdir "$PAIR/$name"
 hdiutil create -quiet -size 3g -type SPARSE -fs "$fs" -volname "BM_${name}" -o "$PAIR/$name.sparseimage"
 # Record intent before attach so a signal or partial attachment is cleaned.
 MOUNTS+=("$PAIR/$name")
 hdiutil attach -quiet -nobrowse -mountpoint "$PAIR/$name" "$PAIR/$name.sparseimage"
 python3 - "$PAIR" "$PAIR/$name" <<'PY'
import os, sys
assert os.stat(sys.argv[1]).st_dev != os.stat(sys.argv[2]).st_dev, 'Expected a mounted image, not a host directory'
PY
 mkdir "$PAIR/$name/tmp"
 touch "$PAIR/$name/.bitmatch-fault-owned"
 expected="${name/apfsx/apfs}"
 if [[ "$name" == hfsx ]]; then expected=hfs; fi
 if [[ "$name" == fat ]]; then expected=msdos; fi
 BITMATCH_FAULT_MATRIX_MOUNT="$PAIR/$name" BITMATCH_FAULT_MATRIX_TYPE="$expected" "${SWIFT[@]}" test \
  --skip-build --disable-swift-testing --no-parallel --package-path "$ROOT/Packages/BitMatchEngine" --scratch-path "$PAIR/build" \
  --filter MountedFilesystemFaultTests \
  > "$LOG_DIR/$name.log" 2>&1 || failed=1
 # A framework-loader failure or a zero-test run is not a successful matrix.
 expected_skips=1
 if [[ "$name" == exfat || "$name" == fat ]]; then expected_skips=0; fi
 python3 - "$LOG_DIR/$name.log" "$expected_skips" <<'PY' || failed=1
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
summaries = re.findall(r'Executed 12 tests, with (?:(\d+) tests? skipped and )?0 failures', text)
assert summaries and all(int(value or 0) == int(sys.argv[2]) for value in summaries), 'Missing, failed or unexpectedly skipped tests'
PY
 echo "Filesystem $name tested; log: $LOG_DIR/$name.log"
done
exit "$failed"
