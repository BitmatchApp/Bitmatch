#!/usr/bin/env bash
# Opt-in, destructive ONLY to disposable images created below our tmp root.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAIR=$(mktemp -d /private/tmp/bitmatch-recovery-XXXXXX)
LOG_DIR=${BITMATCH_RECOVERY_LOG_DIR:-/private/tmp/bitmatch-recovery-results-$(date +%Y%m%d-%H%M%S)}
BUILD_DIR=${BITMATCH_RECOVERY_BUILD_DIR:-/private/tmp/bitmatch-recovery-build}
mkdir -p "$LOG_DIR"
ACTIVE=""
cleanup() {
    if [[ -n "$ACTIVE" ]] && mount | /usr/bin/grep -F " on $ACTIVE (" >/dev/null; then
        if ! hdiutil detach -quiet "$ACTIVE"; then
            echo "Busy image retained; do not delete mounted root: $PAIR" >&2
            return
        fi
    fi
    rm -rf "$PAIR"
}
trap cleanup EXIT
require_execution() {
    python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
rows = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures', text)
if not rows:
    raise SystemExit("No XCTest execution summary: " + sys.argv[1])
count, skipped, failures = rows[-1]
if int(count) != int(sys.argv[2]) or int(skipped or 0) or int(failures):
    raise SystemExit("Wrong execution count/skips/failures: " + repr(rows[-1]) + " in " + sys.argv[1])
PY
}
swift build --build-tests --package-path "$ROOT/Packages/BitMatchEngine" --scratch-path "$BUILD_DIR" --jobs 4 > "$LOG_DIR/build.log" 2>&1
failed=0
for item in 'apfs:APFS:apfs' 'apfsx:Case-sensitive APFS:apfs' 'hfs:JHFS+:hfs' 'exfat:ExFAT:exfat' 'fat:MS-DOS FAT32:msdos'; do
    name=${item%%:*}; rest=${item#*:}; fs=${rest%:*}; expected=${rest##*:}
    mkdir "$PAIR/$name"
    # FAT-family volume labels have tighter length limits than APFS.
    hdiutil create -quiet -size 3g -type SPARSE -fs "$fs" -volname "BMR_$name" -o "$PAIR/$name.sparseimage" > "$LOG_DIR/$name-image.log" 2>&1
    hdiutil attach -quiet -nobrowse -mountpoint "$PAIR/$name" "$PAIR/$name.sparseimage" >> "$LOG_DIR/$name-image.log" 2>&1
    ACTIVE="$PAIR/$name"
    touch "$ACTIVE/.bitmatch-recovery-owned"
    mkdir "$ACTIVE/readonly-target"
    BITMATCH_RECOVERY_MOUNT="$ACTIVE" BITMATCH_RECOVERY_TYPE="$expected" \
        swift test --skip-build --package-path "$ROOT/Packages/BitMatchEngine" --scratch-path "$BUILD_DIR" --jobs 4 \
        --filter MountedDriveRecoveryMatrixTests --skip 'testReadOnlyMountedDestination|testDetachedDestination' \
        > "$LOG_DIR/$name-recovery.log" 2>&1 || failed=1
    require_execution "$LOG_DIR/$name-recovery.log" 10 || failed=1
    BITMATCH_RECOVERY_MOUNT="$ACTIVE" BITMATCH_RECOVERY_TYPE="$expected" BITMATCH_RECOVERY_DETACH=1 \
        swift test --skip-build --package-path "$ROOT/Packages/BitMatchEngine" --scratch-path "$BUILD_DIR" --jobs 4 \
        --filter MountedDriveRecoveryMatrixTests/testDetachedDestinationAfterPreflightFailsWithoutWritingMountpoint \
        > "$LOG_DIR/$name-detach.log" 2>&1 || failed=1
    require_execution "$LOG_DIR/$name-detach.log" 1 || failed=1
    # The detach test must unmount normally; never force a still-busy image.
    if mount | /usr/bin/grep -F " on $ACTIVE (" >/dev/null; then
        hdiutil detach -quiet "$ACTIVE"
    fi
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$ACTIVE" "$PAIR/$name.sparseimage" >> "$LOG_DIR/$name-image.log" 2>&1
    BITMATCH_RECOVERY_MOUNT="$ACTIVE" BITMATCH_RECOVERY_TYPE="$expected" BITMATCH_RECOVERY_READ_ONLY=1 \
        swift test --skip-build --package-path "$ROOT/Packages/BitMatchEngine" --scratch-path "$BUILD_DIR" --jobs 4 \
        --filter MountedDriveRecoveryMatrixTests/testReadOnlyMountedDestinationCannotProduceVerifiedCopy \
        > "$LOG_DIR/$name-readonly.log" 2>&1 || failed=1
    require_execution "$LOG_DIR/$name-readonly.log" 1 || failed=1
    hdiutil detach -quiet "$ACTIVE"
    ACTIVE=""
    rm "$PAIR/$name.sparseimage"
    echo "RECOVERY_FILESYSTEM $name finished; logs: $LOG_DIR/$name-*.log"
done
echo "RECOVERY_RESULT exit=$failed logs=$LOG_DIR"
exit "$failed"
