#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/harness_evidence.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bitmatch-soak.XXXXXX")
MARKER="$WORK/.bitmatch-disposable-fixture"
ENGINE_SCRATCH=${BITMATCH_ENGINE_SCRATCH_PATH:-"$WORK/EngineBuild"}
RESULT="$WORK/soak-result.json"
touch "$MARKER"
mkdir "$WORK/fixtures"
touch "$WORK/fixtures/.bitmatch-disposable-fixture"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -f "$RESULT" ]]; then
    cp "$RESULT" "$EVIDENCE/soak-result.json" || status=1
  fi
  if [[ "$status" == 0 && -f "$MARKER" ]]; then
    rm -rf "$WORK" || status=1
  else
    echo "Preserving failed/interrupted harness directory: $WORK" >&2
  fi
  finish_evidence "$status" || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
initialize_evidence soak

BITMATCH_SOAK_SEED=${BITMATCH_SOAK_SEED:-20260711}
BITMATCH_SOAK_ITERATIONS=${BITMATCH_SOAK_ITERATIONS:-25}
BITMATCH_SOAK_MAX_SECONDS=${BITMATCH_SOAK_MAX_SECONDS:-900}
printf 'seed=%s\niterations=%s\n' "$BITMATCH_SOAK_SEED" "$BITMATCH_SOAK_ITERATIONS" >> "$EVIDENCE/environment.txt"
[[ "$BITMATCH_SOAK_SEED" =~ ^[0-9]+$ ]] || { echo "BITMATCH_SOAK_SEED must be unsigned" >&2; exit 64; }
[[ "$BITMATCH_SOAK_ITERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "BITMATCH_SOAK_ITERATIONS must be positive" >&2; exit 64; }

# The soak suite lives in the engine package, not the app's XCTest target.
# Explicit testability supports Release @testable imports with the native builder.
/usr/bin/xcrun swift build --package-path "$ROOT/Packages/BitMatchEngine" \
  --scratch-path "$ENGINE_SCRATCH" --build-system native --jobs 4 \
  --configuration release --build-tests -Xswiftc -enable-testing 2>&1 | tee "$EVIDENCE/build.log"
BIN=$(/usr/bin/xcrun swift build --package-path "$ROOT/Packages/BitMatchEngine" \
  --scratch-path "$ENGINE_SCRATCH" --build-system native --configuration release --show-bin-path)
ENVIRONMENT=$(/usr/bin/python3 - "$BITMATCH_SOAK_SEED" "$BITMATCH_SOAK_ITERATIONS" "$RESULT" "$WORK/fixtures/" <<'PY'
import json, sys
seed, iterations = int(sys.argv[1]), int(sys.argv[2])
assert 0 <= seed < 1 << 64 and iterations > 0
print(json.dumps({'BITMATCH_RUN_SOAK': '1', 'BITMATCH_SOAK_SEED': str(seed),
                  'BITMATCH_SOAK_ITERATIONS': str(iterations), 'BITMATCH_SOAK_RESULT': sys.argv[3], 'BITMATCH_SOAK_FIXTURE_ROOT': sys.argv[4]}))
PY
)
/usr/bin/python3 "$ROOT/Scripts/guarded_engine_xctest.py" \
  --work "$WORK" --bundle "$BIN/BitMatchEnginePackageTests.xctest" \
  --selected BitMatchEngineTests.TransferSoakTests/testSeededStandardTransferToTwoDestinations \
  --environment "$ENVIRONMENT" --max-seconds "$BITMATCH_SOAK_MAX_SECONDS" 2>&1 | tee "$EVIDENCE/guard.log"
cp "$WORK/worker.log" "$EVIDENCE/test.log"
cp "$WORK/worker-memory.json" "$EVIDENCE/memory.json"
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "$ROOT/Scripts" "$RESULT" "$BITMATCH_SOAK_SEED" "$BITMATCH_SOAK_ITERATIONS" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from guarded_engine_xctest import validate_soak
value = json.load(open(sys.argv[2]))
validate_soak(value, int(sys.argv[3]), int(sys.argv[4]))
print('SOAK validated actualIterations={} sourceHashesBefore={} sourceHashesAfter={} destinationHashes={}'.format(
    value['completedIterations'], sum(row['sourceHashesBefore'] for row in value['iterations']),
    sum(row['sourceHashesAfter'] for row in value['iterations']), sum(row['verifiedOutputs'] for row in value['iterations'])))
PY
cp "$RESULT" "$EVIDENCE/soak-result.json"
