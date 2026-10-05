#!/usr/bin/env bash
# Eight synthetic clips, two large tail clips; real exFAT -> HFS+ drivers.
# Virtual disks share the host disk: this is not a USB/dock reproduction.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PAIR=$(mktemp -d /tmp/bitmatch-large-verify.XXXXXX)
MOUNTS=()
cleanup() {
  local busy=0
  for mount in "${MOUNTS[@]}"; do hdiutil detach -quiet "$mount" || busy=1; done
  if [[ "$busy" == 0 ]]; then rm -rf "$PAIR"; else echo "Busy disposable images retained: $PAIR" >&2; fi
}
trap cleanup EXIT
mkdir "$PAIR/source" "$PAIR/destination"
for role in source destination; do
  fs=ExFAT; size=12g; [[ "$role" == destination ]] && fs=JHFS+ && size=24g
  hdiutil create -quiet -size "$size" -type SPARSE -fs "$fs" -volname "BM_VERIFY" -o "$PAIR/$role.sparseimage"
  hdiutil attach -quiet -nobrowse -mountpoint "$PAIR/$role" "$PAIR/$role.sparseimage"
  MOUNTS+=("$PAIR/$role")
done
SWIFT=(swift)
if [[ "$(uname -m)" == arm64 ]]; then SWIFT=(arch -arm64 swift); fi
BITMATCH_LARGE_VERIFY_ROOT="$PAIR" "${SWIFT[@]}" test --package-path "$ROOT/Packages/BitMatchEngine" --build-system native --filter LargeVerificationTests
