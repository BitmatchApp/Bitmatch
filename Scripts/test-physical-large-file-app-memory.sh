#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORKLOAD=${1:-}
case "$WORKLOAD" in
  smoke|large) ;;
  *) echo "Usage: $0 smoke|large" >&2; exit 64 ;;
esac

CONFIG=${BITMATCH_PHYSICAL_LARGE_FILE_CONFIG:?Set BITMATCH_PHYSICAL_LARGE_FILE_CONFIG to the private marked hardware config}
EVIDENCE_BASE=${BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_BASE:?Set BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_BASE to an existing private evidence directory}
DERIVED_DATA=${BITMATCH_PHYSICAL_LARGE_FILE_DERIVED_DATA:?Set BITMATCH_PHYSICAL_LARGE_FILE_DERIVED_DATA outside the checkout}

python3 - "$ROOT" "$CONFIG" "$EVIDENCE_BASE" "$DERIVED_DATA" <<'PY'
import shutil
import sys
from pathlib import Path

root, config, evidence, derived = (Path(value).resolve() for value in sys.argv[1:])
private_tmp = Path("/private/tmp").resolve()
for label, path in (("hardware config", config), ("evidence base", evidence), ("DerivedData", derived)):
    if path == private_tmp or private_tmp not in path.parents:
        raise SystemExit(f"{label} must be inside private temporary storage")
if not config.is_file():
    raise SystemExit("The private hardware config must exist")
if not evidence.is_dir():
    raise SystemExit("The private evidence base must already exist")
if root == derived or root in derived.parents:
    raise SystemExit("DerivedData must be outside the checkout")
if shutil.disk_usage(root).free < 50 * 1024**3:
    raise SystemExit("Host free space is below the 50 GiB run floor")
PY

mkdir -p "$DERIVED_DATA"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
RUN_ROOT="$EVIDENCE_BASE/physical-large-app-$WORKLOAD-$RUN_ID"
mkdir "$RUN_ROOT"
LOG="$RUN_ROOT/test.log"
APP_EVIDENCE_ROOT="$RUN_ROOT/evidence"
RESULT_BUNDLE="$RUN_ROOT/PhysicalLargeFileAppMemory.xcresult"

if [[ "$WORKLOAD" == "smoke" ]]; then
  WORKLOAD_OPT_IN=(
    BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY=0
    BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE=0
    TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY=0
    TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE=1
  )
else
  WORKLOAD_OPT_IN=(
    BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY=0
    BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE=0
    TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE=0
    TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY=1
  )
fi

set +e
env \
  TEST_RUNNER_BITMATCH_HARDWARE_APP_WORKFLOW=1 \
  TEST_RUNNER_BITMATCH_HARDWARE_CONFIG="$CONFIG" \
  TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_ROOT="$APP_EVIDENCE_ROOT" \
  "${WORKLOAD_OPT_IN[@]}" \
  xcodebuild -project "$ROOT/BitMatch.xcodeproj" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    CODE_SIGNING_ALLOWED=NO \
    test -scheme BitMatch -destination 'platform=macOS' -jobs 2 \
    -parallel-testing-enabled NO \
    -only-testing:BitMatchTests/PhysicalLargeFileAppMemoryTests/testOptInLargeFilePhysicalAppMemory \
    > "$LOG" 2>&1
XCODE_STATUS=$?
set -e

if ! python3 "$ROOT/Scripts/validate_physical_large_file_app_memory.py" \
  --log "$LOG" --evidence-root "$APP_EVIDENCE_ROOT" \
  --workload "$WORKLOAD" --xcode-status "$XCODE_STATUS"; then
  echo "Physical app-memory probe failed validation; log, result bundle, receipt, and fixtures remain at $RUN_ROOT" >&2
  exit 1
fi

echo "Physical app-memory probe evidence: $RUN_ROOT"
