#!/bin/bash
#
# verify_release_app.sh APP
#
# Fails when a Release ThermoTune.app isn't fit to ship. make_dmg.sh runs it
# before packaging, so `make dmg` and the release workflow stop here instead of
# publishing an app that can't change fan speeds.
#
# Most of what it checks fails silently in the app: with no embedded helper,
# Install Helper… reports it missing; with the App Sandbox on, IOKit can't open
# AppleSMC and every reading is empty.

set -euo pipefail

APP="${1:?usage: verify_release_app.sh APP}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO="$APP/Contents/Info.plist"
HELPER="$APP/Contents/MacOS/ThermoTuneHelper"
FAILURES=0

fail() {
    echo "verify_release_app: $1" >&2
    FAILURES=$((FAILURES + 1))
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

[ -f "$INFO" ] || { echo "verify_release_app: no Info.plist in $APP" >&2; exit 1; }

# Version: the bundle must carry the project's MARKETING_VERSION, which the
# release workflow uses for the tag and the DMG name, and the window title shows.
EXPECTED_VERSION=$(sed -nE 's/.*MARKETING_VERSION = ([^;]+);.*/\1/p' "$ROOT/ThermoTune.xcodeproj/project.pbxproj" | sort -u)
ACTUAL_VERSION=$(plist_value "$INFO" CFBundleShortVersionString)
[ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] \
    || fail "version is '$ACTUAL_VERSION', expected MARKETING_VERSION '$EXPECTED_VERSION'"

# The helper is what Install Helper… copies into /Library/PrivilegedHelperTools.
[ -x "$HELPER" ] || fail "no executable helper at Contents/MacOS/ThermoTuneHelper"

# No App Sandbox: a sandboxed app can't open AppleSMC.
ENTITLEMENTS=$(mktemp)
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
[ "$(plist_value "$ENTITLEMENTS" com.apple.security.app-sandbox)" != "true" ] \
    || fail "the App Sandbox is on, so the SMC can't be read"

# A signature that holds across nested code. Apple silicon won't run unsigned
# code at all; ad hoc is enough.
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "code signature doesn't verify"
codesign --verify --strict "$HELPER" 2>/dev/null || fail "the helper's signature doesn't verify"

# The DMG is universal, app and helper alike.
for binary in "$APP/Contents/MacOS/ThermoTune" "$HELPER"; do
    ARCHS=$(lipo -archs "$binary" 2>/dev/null || true)
    for arch in arm64 x86_64; do
        case " $ARCHS " in
            *" $arch "*) ;;
            *) fail "$(basename "$binary") has no $arch slice (has: ${ARCHS:-none})" ;;
        esac
    done
done

if [ "$FAILURES" -gt 0 ]; then
    echo "verify_release_app: $FAILURES problem(s) in $APP" >&2
    exit 1
fi
echo "verify_release_app: $APP is ready to ship ($ACTUAL_VERSION)"
