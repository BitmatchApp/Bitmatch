#!/usr/bin/env bash
# Generated clips only; no camera footage or downloaded assets.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v ffmpeg >/dev/null || { echo "ffmpeg is required to generate codec fixtures" >&2; exit 1; }
PAIR=$(mktemp -d /tmp/bitmatch-codecs.XXXXXX)
LOG_DIR="$ROOT/dist/validation/report-codecs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
touch "$PAIR/.bitmatch-codec-owned"
trap 'rm -rf "$PAIR"' EXIT
make_clip() {
  local name=$1
  shift
  ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=320x180:rate=5 -t 1 -threads 1 "$@" "$PAIR/$name"
}
make_clip h264.mp4 -c:v libx264
make_clip hevc.MOV -c:v libx265 -tag:v hvc1 -x265-params pools=1:frame-threads=1:log-level=error
make_clip prores.mov -c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le
make_clip h264.m4v -c:v libx264
printf 'not a movie' > "$PAIR/broken.mov"
printf 'synthetic proprietary placeholder' > "$PAIR/unsupported.braw"
TEST_RUNNER_BITMATCH_CODEC_FIXTURE_ROOT="$PAIR" \
TEST_RUNNER_BITMATCH_PREVIEW_PDF_OUTPUT="$LOG_DIR" \
xcodebuild -project "$ROOT/BitMatch.xcodeproj" \
 -derivedDataPath "${REPORT_DERIVED_DATA:-$ROOT/.derived-data/mac-test}" CODE_SIGNING_ALLOWED=NO \
 test -scheme BitMatch -destination 'platform=macOS' -only-testing:BitMatchTests/ReportThumbnailTests \
 > "$LOG_DIR/test.log" 2>&1
cat "$LOG_DIR/test.log"
