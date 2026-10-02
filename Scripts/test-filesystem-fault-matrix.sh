#!/usr/bin/env bash
# Run the fault/reuse/safety suites with fixtures on each real filesystem.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAIR=$(mktemp -d /tmp/bitmatch-fault-matrix.XXXXXX)
LOG_DIR="$ROOT/dist/validation/fault-matrix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
MOUNTS=()
cleanup() {
 local busy=0
 for mount in "${MOUNTS[@]}"; do hdiutil detach -quiet "$mount" || busy=1; done
 if [[ "$busy" == 0 ]]; then rm -rf "$PAIR"; else echo "Busy images retained: $PAIR" >&2; fi
}
trap cleanup EXIT
swift build --build-tests --package-path "$ROOT/Packages/BitMatchEngine" > "$LOG_DIR/build.log" 2>&1
failed=0
for item in 'apfs:APFS' 'hfs:JHFS+' 'exfat:ExFAT' 'apfsx:Case-sensitive APFS'; do
 name=${item%%:*}; fs=${item#*:}
 mkdir "$PAIR/$name"
 hdiutil create -size 3g -type SPARSE -fs "$fs" -volname "BM_${name}" -o "$PAIR/$name.sparseimage"
 hdiutil attach -quiet -nobrowse -mountpoint "$PAIR/$name" "$PAIR/$name.sparseimage"
 MOUNTS+=("$PAIR/$name")
 mkdir "$PAIR/$name/tmp"
 touch "$PAIR/$name/.bitmatch-fault-owned"
 BITMATCH_FAULT_MATRIX_MOUNT="$PAIR/$name" BITMATCH_FAULT_MATRIX_TYPE="${name/apfsx/apfs}" swift test --skip-build --package-path "$ROOT/Packages/BitMatchEngine" \
  --filter MountedFilesystemFaultTests \
  > "$LOG_DIR/$name.log" 2>&1 || failed=1
 echo "Filesystem $name tested; log: $LOG_DIR/$name.log"
done
exit "$failed"
