#!/bin/bash
# Point the Homebrew cask at a published release.
# Usage: Scripts/bump_cask.sh <version>   (after the GitHub release exists)
set -euo pipefail
VERSION="${1:?usage: bump_cask.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHA_FILE="$ROOT/dist/BitMatch-$VERSION.dmg.sha256"
[ -f "$SHA_FILE" ] || { echo "Missing $SHA_FILE (run release_mac.sh first)"; exit 1; }
SHA="$(cut -d' ' -f1 "$SHA_FILE")"

# The published file must be the one we checksummed.
PUBLISHED="$(curl -fsSL "https://github.com/BitmatchApp/Bitmatch/releases/download/v$VERSION/BitMatch-$VERSION.dmg" | shasum -a 256 | cut -d' ' -f1)"
[ "$PUBLISHED" = "$SHA" ] || { echo "Published DMG checksum $PUBLISHED does not match $SHA"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone BitmatchApp/homebrew-tap "$WORK/tap" -- -q
CASK="$WORK/tap/Casks/bitmatch.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$WORK/tap" diff --quiet && { echo "Cask already at $VERSION"; exit 0; }
git -C "$WORK/tap" commit -qam "BitMatch $VERSION"
git -C "$WORK/tap" push -q origin main
HOMEBREW_NO_AUTO_UPDATE=1 brew update-reset "$(brew --repository bitmatchapp/tap)" >/dev/null 2>&1 || true
HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask --online bitmatchapp/tap/bitmatch
echo "Cask now at $VERSION ($SHA)"
