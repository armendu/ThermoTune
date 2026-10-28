#!/bin/bash
#
# make_dmg.sh APP OUTPUT_DIR
#
# Packages a Release build of ThermoTune.app as OUTPUT_DIR/ThermoTune-<version>.dmg,
# with an Applications shortcut to drag it onto. Prints the DMG's path.
#
# ThermoTune has no Developer ID, so the app keeps the ad hoc signature Xcode
# gives it and isn't notarized: macOS asks people to allow it once, in Privacy &
# Security. Re-signing here would also change the embedded helper's bytes, which
# the app compares with the installed helper.

set -euo pipefail

APP="${1:?usage: make_dmg.sh APP OUTPUT_DIR}"
OUTPUT_DIR="${2:?usage: make_dmg.sh APP OUTPUT_DIR}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/Scripts/verify_release_app.sh" "$APP" >&2

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/dmg" "$OUTPUT_DIR"
# ditto keeps the bundle's symlinks, permissions and signature exactly as built.
ditto "$APP" "$WORK/dmg/ThermoTune.app"
ln -s /Applications "$WORK/dmg/Applications"

DMG="$OUTPUT_DIR/ThermoTune-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "ThermoTune $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO "$DMG"
echo "$DMG"
