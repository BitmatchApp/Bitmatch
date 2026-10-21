#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
EVIDENCE_BASE=${BITMATCH_HISTORY_EVIDENCE_BASE:?Set BITMATCH_HISTORY_EVIDENCE_BASE to the private History evidence directory}
DERIVED_DATA_ROOT=${BITMATCH_HISTORY_DERIVED_DATA:?Set BITMATCH_HISTORY_DERIVED_DATA outside Desktop}
ATTEMPTS=${BITMATCH_HISTORY_ATTEMPTS:-500}

case "$EVIDENCE_BASE" in
  /private/tmp/*) ;;
  *) echo "History evidence base must be under /private/tmp" >&2; exit 64 ;;
esac
case "$DERIVED_DATA_ROOT" in
  /private/tmp/*) ;;
  *) echo "DerivedData must be under /private/tmp" >&2; exit 64 ;;
esac
[[ "$DERIVED_DATA_ROOT" != "$ROOT"/* ]] || { echo "DerivedData must be outside the checkout" >&2; exit 64; }
[[ "$ATTEMPTS" =~ ^[0-9]+$ ]] && (( ATTEMPTS >= 100 && ATTEMPTS <= 500 )) \
  || { echo "Attempts must be between 100 and 500" >&2; exit 64; }

mkdir -p "$EVIDENCE_BASE" "$DERIVED_DATA_ROOT"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
RUN_ROOT="$EVIDENCE_BASE/app-host-$RUN_ID"
mkdir "$RUN_ROOT"
LOG="$RUN_ROOT/test.log"

if ! TEST_RUNNER_BITMATCH_HISTORY_APP_PROBE=1 \
  TEST_RUNNER_BITMATCH_HISTORY_ATTEMPTS="$ATTEMPTS" \
  TEST_RUNNER_BITMATCH_HISTORY_EVIDENCE_ROOT="$RUN_ROOT" \
  xcodebuild -project "$ROOT/BitMatch.xcodeproj" \
    -derivedDataPath "$DERIVED_DATA_ROOT" \
    -resultBundlePath "$RUN_ROOT/HistoryProbe.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    test -scheme BitMatch -destination 'platform=macOS' -jobs 2 \
    -parallel-testing-enabled NO \
    -only-testing:BitMatchTests/HistoryAppHostScaleTests/testActualHistoryAppHostScaleProbe \
    > "$LOG" 2>&1; then
  echo "History app-host probe failed; its log and fixture are retained." >&2
  exit 1
fi

python3 - "$LOG" "$RUN_ROOT" "$ATTEMPTS" <<'PY'
import json
import sys
from pathlib import Path

log_path, run_root, attempts_text = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
log = log_path.read_text(errors="replace")
test_lines = [line for line in log.splitlines()
              if "HistoryAppHostScaleTests" in line and "testActualHistoryAppHostScaleProbe" in line]
if not any("passed" in line.lower() for line in test_lines):
    raise SystemExit("The focused app-host probe did not report a passing test case")
if any("skip" in line.lower() for line in test_lines) or "TEST SUCCEEDED" not in log:
    raise SystemExit("Xcode did not report a non-skipped successful focused test run")

receipts = list(run_root.glob("history-app-host-probe-*.json"))
if len(receipts) != 1:
    raise SystemExit("Expected exactly one complete app-host probe receipt")
receipt = json.loads(receipts[0].read_text())
required = {
    "complete": True,
    "attempts": attempts_text,
    "resultRows": attempts_text * 100,
    "coveredRows": attempts_text * 100,
    "recoveredRunningAttempts": 1,
    "durableLegacyRowIDs": 1,
    "queueSummaryRowsBuilt": 8,
    "historyRenderedPNGBytes": 1,
    "queueRenderedPNGBytes": 1,
}
for key, expected in required.items():
    actual = receipt.get(key, 0)
    invalid = actual < expected if key.endswith("PNGBytes") else actual != expected
    if invalid:
        raise SystemExit(f"Receipt is incomplete: {key}")
if receipt.get("missingMemorySample") or not 0 < receipt.get("memorySamples", 0):
    raise SystemExit("Receipt is missing process-memory observations")
if receipt.get("peakPhysicalFootprintMiB", 1024) >= 1024:
    raise SystemExit("Receipt exceeded the 1 GiB app-test footprint bound")
if not receipt.get("maximumMainActorDelayMilliseconds", 0) > 0:
    raise SystemExit("Receipt is missing main-actor responsiveness observations")
phase_delays = receipt.get("maximumMainActorDelayMillisecondsByPhase", {})
for phase in ("fixturePreparation", "historySearch", "historyViewLayout", "queueViewLayout"):
    if not phase_delays.get(phase, 0) > 0:
        raise SystemExit(f"Receipt is missing main-actor responsiveness observations for {phase}")
if "HISTORY_APP_HOST_PROBE " not in log:
    raise SystemExit("The test log is missing its completed probe summary")

print(f"History app-host probe passed: {attempts_text} attempts, {attempts_text * 100} result rows; complete receipt verified.")
print(f"Observed peak process footprint: {receipt['peakPhysicalFootprintMiB']} MiB; maximum main-actor pulse delay: {receipt['maximumMainActorDelayMilliseconds']:.1f} ms.")
PY
