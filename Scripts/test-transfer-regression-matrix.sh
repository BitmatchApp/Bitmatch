#!/usr/bin/env bash
# Baseline fault/real-exFAT coverage + seeded two-destination soak + Mac handoff.
# This is a regression subset, not a hardware-disconnect or all-filesystem matrix.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG_DIR="$ROOT/dist/validation/matrix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
swift test --package-path "$ROOT/Packages/BitMatchEngine" > "$LOG_DIR/engine.log" 2>&1
BITMATCH_RUN_SOAK=1 \
BITMATCH_SOAK_SEED="${BITMATCH_SOAK_SEED:-20261001}" \
BITMATCH_SOAK_ITERATIONS="${BITMATCH_SOAK_ITERATIONS:-100}" \
swift test --package-path "$ROOT/Packages/BitMatchEngine" --filter TransferSoakTests > "$LOG_DIR/soak.log" 2>&1
bash "$ROOT/Scripts/test-issue10-filesystem-pair.sh" > "$LOG_DIR/filesystem-pair.log" 2>&1
if [[ "${BITMATCH_EXTENDED_MATRIX:-0}" == 1 ]]; then
  failed=0
  bash "$ROOT/Scripts/test-filesystem-fault-matrix.sh" > "$LOG_DIR/faults.log" 2>&1 || failed=1
  bash "$ROOT/Scripts/test-full-transfer-matrix.sh" > "$LOG_DIR/full.log" 2>&1 || failed=1
  MATRIX_FOCUS=collision bash "$ROOT/Scripts/test-full-transfer-matrix.sh" > "$LOG_DIR/collisions.log" 2>&1 || failed=1
  if [[ "$failed" != 0 ]]; then echo "Extended matrix has failures. Logs: $LOG_DIR" >&2; exit 1; fi
fi
echo "Regression matrix passed. Logs: $LOG_DIR"
