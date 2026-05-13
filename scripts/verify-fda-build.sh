#!/bin/bash

# Non-destructive diagnostics for FDA/TCC build identity.
# This script does not reset TCC, modify permissions, or change the app bundle.

set -u

APP_PATH="${1:-MacPersistenceChecker.app}"
CODESIGN="/usr/bin/codesign"
PLISTBUDDY="/usr/libexec/PlistBuddy"
SPCTL="/usr/sbin/spctl"

run_check() {
    local title="$1"
    shift

    echo ""
    echo "== $title =="
    echo "$*"
    "$@" 2>&1
    local status=$?
    echo "exit status: $status"
}

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: app bundle not found: $APP_PATH"
    echo "Usage: scripts/verify-fda-build.sh /path/to/MacPersistenceChecker.app"
    exit 2
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
    echo "ERROR: Info.plist not found at $INFO_PLIST"
    exit 2
fi

BUNDLE_ID="$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || true)"

echo "=== MacPersistenceChecker FDA Build Diagnostics ==="
echo "App path:  $APP_PATH"
echo "Bundle ID: ${BUNDLE_ID:-unknown}"

run_check "codesign verify" "$CODESIGN" --verify --verbose=4 "$APP_PATH"
run_check "codesign designated requirement" "$CODESIGN" -dvvv -r- "$APP_PATH"
run_check "Gatekeeper assessment" "$SPCTL" --assess --type execute --verbose=4 "$APP_PATH"

echo ""
echo "== Optional TCC log command =="
echo "Run this in a separate terminal while granting Full Disk Access:"
echo "/usr/bin/log stream --predicate 'subsystem == \"com.apple.TCC\" OR process == \"tccd\"' --info"

echo ""
echo "This script is read-only. It does not reset TCC or modify Full Disk Access."
