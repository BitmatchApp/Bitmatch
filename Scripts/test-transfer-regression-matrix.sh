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
echo "Regression matrix passed. Logs: $LOG_DIR"
