#!/bin/bash

# MacPersistenceChecker Build Script
# Creates a complete .app bundle ready for distribution

set -e

echo "=== MacPersistenceChecker Build Script ==="
echo ""

# Configuration
APP_NAME="MacPersistenceChecker"
VERSION="2.0.0"
BUNDLE_ID="com.pinperepette.MacPersistenceChecker"
MIN_MACOS="13.0"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
REQUIRE_STABLE_SIGNING="${REQUIRE_STABLE_SIGNING:-0}"

# System tools used for bundle cleanup and signing. These are absolute paths
# so a broken Homebrew shim earlier on PATH cannot change build behavior.
XATTR="/usr/bin/xattr"
CODESIGN="/usr/bin/codesign"
LIPO="/usr/bin/lipo"
DU="/usr/bin/du"
MKTEMP="/usr/bin/mktemp"
SECURITY="/usr/bin/security"

if [ "$REQUIRE_STABLE_SIGNING" = "1" ] && [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "ERROR: REQUIRE_STABLE_SIGNING=1 requires SIGNING_IDENTITY to name a stable code-signing identity."
    echo "Example: SIGNING_IDENTITY=\"Developer ID Application: Example Corp (TEAMID)\" REQUIRE_STABLE_SIGNING=1 ./build.sh"
    exit 2
fi

if [ "$SIGNING_IDENTITY" != "-" ]; then
    if ! "$SECURITY" find-identity -v -p codesigning | grep -F -- "$SIGNING_IDENTITY" >/dev/null; then
        echo "ERROR: signing identity not found: $SIGNING_IDENTITY"
        echo "Use one of the identities listed by:"
        echo "  /usr/bin/security find-identity -v -p codesigning"
        exit 2
    fi
fi

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TEMP_DIR="$("$MKTEMP" -d "${TMPDIR:-/tmp}/mpc-build.XXXXXX")"
ENTITLEMENTS_FILE="$TEMP_DIR/entitlements.plist"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Tool preflight:"
echo "    xattr:    $XATTR (PATH resolves to: $(command -v xattr || echo "not found"))"
echo "    codesign: $CODESIGN (PATH resolves to: $(command -v codesign || echo "not found"))"
echo "    swift:    $(command -v swift || echo "not found")"
echo "    lipo:     $LIPO (PATH resolves to: $(command -v lipo || echo "not found"))"
echo "    signing: $SIGNING_IDENTITY"
echo ""

# Clean previous build
echo "[1/6] Cleaning previous build..."
rm -rf "$APP_DIR"

# Build release binary (universal: arm64 + x86_64) so the app runs natively
# on Apple Silicon (M1/M2/M3/M4) and Intel Macs without Rosetta.
# Set UNIVERSAL=0 to build only for the host architecture.
echo "[2/6] Building release binary..."
cd "$SCRIPT_DIR"
UNIVERSAL="${UNIVERSAL:-1}"
if [ "$UNIVERSAL" = "1" ]; then
    echo "    Building universal (arm64 + x86_64)..."
    swift build -c release --triple arm64-apple-macosx${MIN_MACOS}
    swift build -c release --triple x86_64-apple-macosx${MIN_MACOS}
    mkdir -p "$BUILD_DIR/release"
    "$LIPO" -create \
        "$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME" \
        "$BUILD_DIR/x86_64-apple-macosx/release/$APP_NAME" \
        -output "$BUILD_DIR/release/$APP_NAME"
    echo "    Architectures: $("$LIPO" -archs "$BUILD_DIR/release/$APP_NAME")"
else
    swift build -c release
fi

# Create app bundle structure
echo "[3/6] Creating app bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary
cp "$BUILD_DIR/release/$APP_NAME" "$MACOS_DIR/"

# Copy icon
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/"
    echo "    Icon: AppIcon.icns copied"
fi

# Copy SwiftPM resource bundle contents into the app Resources/ so that
# Bundle.main.url(forResource:) finds them at runtime (KnownVendors.json,
# AIPrompts/*.md, etc.). The arm64 build's resource bundle is identical to
# the x86_64 one, so we copy from whichever exists.
RESOURCE_BUNDLE_NAMES=(
    "$BUILD_DIR/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
    "$BUILD_DIR/x86_64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
    "$BUILD_DIR/release/${APP_NAME}_${APP_NAME}.bundle"
)
for bundle in "${RESOURCE_BUNDLE_NAMES[@]}"; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle"/* "$RESOURCES_DIR/" 2>/dev/null || true
        echo "    Resources: copied from $(basename "$(dirname "$bundle")")/"
        break
    fi
done

# Create Info.plist
echo "[4/6] Creating Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Persistence Checker</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024 Pinperepette. All rights reserved.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

# Create entitlements
echo "[5/6] Creating entitlements and signing..."
cat > "$ENTITLEMENTS_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
EOF

# Remove quarantine and sign
"$XATTR" -cr "$APP_DIR"
"$CODESIGN" --force --deep --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" "$APP_DIR"

echo "    Verifying signature..."
"$CODESIGN" --verify --verbose=4 "$APP_DIR"

echo "    Code signing details:"
SIGNING_DETAILS="$("$CODESIGN" -dvvv -r- "$APP_DIR" 2>&1)"
echo "$SIGNING_DETAILS"

SIGNATURE_LINE="$(printf '%s\n' "$SIGNING_DETAILS" | awk -F= '/^Signature=/{print $2; exit}')"
TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNING_DETAILS" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
DESIGNATED_REQUIREMENT="$(printf '%s\n' "$SIGNING_DETAILS" | sed -n 's/^# designated => //p')"

if [[ "$SIGNATURE_LINE" == "adhoc" ]]; then
    echo "WARNING: Signature=adhoc."
fi

if [[ "$SIGNING_DETAILS" == *"designated => cdhash"* ]]; then
    echo "WARNING: designated requirement is cdhash-only."
fi

if [[ "$SIGNING_DETAILS" == *"designated => cdhash"* || "$SIGNING_DETAILS" == *"TeamIdentifier=not set"* ]]; then
    echo "WARNING: ad-hoc signing creates a build-specific TCC identity; FDA grants may not survive rebuilds."
fi

if [ "$REQUIRE_STABLE_SIGNING" = "1" ] && [ "${TEAM_IDENTIFIER:-not set}" = "not set" ]; then
    echo "WARNING: TeamIdentifier=not set; this is not a Developer ID style identity even if the certificate requirement is stable."
fi

if [[ "$SIGNATURE_LINE" != "adhoc" && "$SIGNING_DETAILS" != *"designated => cdhash"* ]]; then
    echo "Stable signing check: designated requirement is not cdhash-only."
    echo "Durable TCC identity: $DESIGNATED_REQUIREMENT"
elif [ "$REQUIRE_STABLE_SIGNING" = "1" ]; then
    echo "ERROR: REQUIRE_STABLE_SIGNING=1 expected a non-ad-hoc, non-cdhash-only designated requirement."
    exit 3
fi

# Done
echo "[6/6] Build complete!"
echo ""
echo "=== Build Summary ==="
echo "App:     $APP_DIR"
echo "Version: $VERSION"
echo "Size:    $("$DU" -sh "$APP_DIR" | cut -f1)"
echo ""
echo "To install, run:"
echo "  cp -r $APP_NAME.app /Applications/"
echo ""
echo "Or drag $APP_NAME.app to your Applications folder."
