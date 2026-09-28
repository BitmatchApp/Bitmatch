#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+([.][0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: Scripts/publish_appcast.sh <version>" >&2
  exit 64
fi

VERSION=$1
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT=${PROJECT:-BitMatch.xcodeproj}
SCHEME=${SCHEME:-BitMatch}
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-$ROOT_DIR/dist/DerivedData}
DMG_PATH="$ROOT_DIR/dist/BitMatch-$VERSION.dmg"
APP_PLIST="$ROOT_DIR/dist/BitMatch-$VERSION.xcarchive/Products/Applications/BitMatch.app/Contents/Info.plist"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bitmatch-appcast.XXXXXX")
SITE_DIR="$TEMP_DIR/bitmatchapp.github.io"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

for command in gh git xcodebuild /usr/bin/python3 /usr/libexec/PlistBuddy; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 69
  fi
done

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release image not found: $DMG_PATH" >&2
  exit 66
fi

if [[ ! -f "$APP_PLIST" ]]; then
  echo "Archived app Info.plist not found: $APP_PLIST" >&2
  echo "Run Scripts/release_mac.sh $VERSION first." >&2
  exit 66
fi

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")

if [[ "$SHORT_VERSION" != "$VERSION" ]]; then
  echo "Archive version $SHORT_VERSION does not match requested version $VERSION." >&2
  exit 65
fi

resolved_sparkle_version() {
  /usr/bin/python3 - "$@" <<'PY'
import json
import pathlib
import sys

for candidate in sys.argv[1:]:
    path = pathlib.Path(candidate)
    if not path.is_file():
        continue
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        continue
    pins = data.get("pins", data.get("object", {}).get("pins", []))
    dependencies = data.get("object", {}).get("dependencies", [])
    for pin in [*pins, *dependencies]:
        identity = (pin.get("identity") or pin.get("package") or "").lower()
        location = (pin.get("location") or pin.get("repositoryURL") or "").lower()
        package_ref = pin.get("packageRef", {})
        identity = identity or (package_ref.get("identity") or package_ref.get("name") or "").lower()
        location = location or (package_ref.get("location") or "").lower()
        if identity == "sparkle" or location.rstrip("/").endswith("/sparkle"):
            state = pin.get("state", {})
            version = state.get("version") or state.get("checkoutState", {}).get("version")
            if version:
                print(version)
                raise SystemExit(0)
raise SystemExit(1)
PY
}

PACKAGE_RESOLVED_FILES=(
  "$ROOT_DIR/BitMatch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  "$DERIVED_DATA_PATH/SourcePackages/Package.resolved"
  "$DERIVED_DATA_PATH/SourcePackages/workspace-state.json"
)

SPARKLE_VERSION=$(resolved_sparkle_version "${PACKAGE_RESOLVED_FILES[@]}" 2>/dev/null || true)
if [[ -z "$SPARKLE_VERSION" ]]; then
  echo "Resolving Swift package versions"
  xcodebuild -resolvePackageDependencies \
    -project "$ROOT_DIR/$PROJECT" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH"
  SPARKLE_VERSION=$(resolved_sparkle_version "${PACKAGE_RESOLVED_FILES[@]}" 2>/dev/null || true)
fi

if [[ -z "$SPARKLE_VERSION" ]]; then
  echo "Could not determine the resolved Sparkle version." >&2
  exit 65
fi

SIGN_UPDATE=$(find "$DERIVED_DATA_PATH/SourcePackages/artifacts" -type f -path "*/bin/sign_update" -not -path "*old_dsa*" -perm -111 -print -quit 2>/dev/null || true)
if [[ -z "$SIGN_UPDATE" ]]; then
  SPARKLE_RELEASE_DIR="$TEMP_DIR/sparkle-release"
  mkdir -p "$SPARKLE_RELEASE_DIR"
  echo "Downloading Sparkle $SPARKLE_VERSION release tools"
  gh release download "$SPARKLE_VERSION" \
    --repo sparkle-project/Sparkle \
    --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" \
    --dir "$SPARKLE_RELEASE_DIR"
  tar -xf "$SPARKLE_RELEASE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$SPARKLE_RELEASE_DIR"
  SIGN_UPDATE=$(find "$SPARKLE_RELEASE_DIR" -type f -path "*/bin/sign_update" -not -path "*old_dsa*" -perm -111 -print -quit 2>/dev/null || true)
fi

if [[ -z "$SIGN_UPDATE" ]]; then
  echo "Sparkle's sign_update tool was not found." >&2
  exit 66
fi

echo "Signing BitMatch-$VERSION.dmg with the BitMatch Sparkle key (Keychain account "bitmatch")"
SIGN_OUTPUT=$("$SIGN_UPDATE" --account bitmatch "$DMG_PATH")
ED_SIGNATURE=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN_OUTPUT")
FILE_LENGTH=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIGN_OUTPUT")

if [[ -z "$ED_SIGNATURE" || -z "$FILE_LENGTH" ]]; then
  echo "sign_update did not return an EdDSA signature and file length." >&2
  exit 65
fi

echo "Cloning the appcast site"
gh repo clone BitmatchApp/bitmatchapp.github.io "$SITE_DIR" -- --depth=1
APPCAST_PATH="$SITE_DIR/appcast.xml"
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

APPCAST_VERSION="$VERSION" \
APPCAST_BUNDLE_VERSION="$BUNDLE_VERSION" \
APPCAST_SHORT_VERSION="$SHORT_VERSION" \
APPCAST_PUB_DATE="$PUB_DATE" \
APPCAST_SIGNATURE="$ED_SIGNATURE" \
APPCAST_LENGTH="$FILE_LENGTH" \
/usr/bin/python3 - "$APPCAST_PATH" <<'PY'
import os
import pathlib
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

path = pathlib.Path(__import__("sys").argv[1])
if path.exists():
    tree = ET.parse(path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("appcast.xml has no channel element")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "BitMatch Updates"
    ET.SubElement(channel, "link").text = "https://bitmatchapp.github.io/"
    ET.SubElement(channel, "description").text = "BitMatch release updates"
    tree = ET.ElementTree(root)

version = os.environ["APPCAST_VERSION"]
download_url = f"https://github.com/BitmatchApp/Bitmatch/releases/download/v{version}/BitMatch-{version}.dmg"

for old_item in list(channel.findall("item")):
    old_version = old_item.findtext(f"{{{SPARKLE_NS}}}shortVersionString")
    enclosure = old_item.find("enclosure")
    old_url = enclosure.get("url") if enclosure is not None else None
    if old_version == version or old_url == download_url:
        channel.remove(old_item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = os.environ["APPCAST_BUNDLE_VERSION"]
ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = os.environ["APPCAST_SHORT_VERSION"]
ET.SubElement(item, "pubDate").text = os.environ["APPCAST_PUB_DATE"]
ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = (
    f"https://github.com/BitmatchApp/Bitmatch/releases/tag/v{version}"
)
ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "15.5"
ET.SubElement(
    item,
    "enclosure",
    {
        "url": download_url,
        f"{{{SPARKLE_NS}}}edSignature": os.environ["APPCAST_SIGNATURE"],
        "length": os.environ["APPCAST_LENGTH"],
        "type": "application/octet-stream",
    },
)

first_item_index = next(
    (index for index, child in enumerate(channel) if child.tag == "item"),
    len(channel),
)
channel.insert(first_item_index, item)
ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
PY

git -C "$SITE_DIR" add appcast.xml
git -C "$SITE_DIR" commit -m "Publish BitMatch $VERSION appcast"
git -C "$SITE_DIR" push

echo "Published BitMatch $VERSION in appcast.xml"
