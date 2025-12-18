#!/bin/bash

# MacPersistenceChecker Build Script
# Creates a complete .app bundle ready for distribution

set -e

echo "=== MacPersistenceChecker Build Script ==="
echo ""

# Configuration
APP_NAME="MacPersistenceChecker"
VERSION="1.4.0"
BUNDLE_ID="com.pinperepette.MacPersistenceChecker"
MIN_MACOS="13.0"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Clean previous build
echo "[1/6] Cleaning previous build..."
rm -rf "$APP_DIR"

# Build release binary
echo "[2/6] Building release binary..."
cd "$SCRIPT_DIR"
swift build -c release

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
cat > /tmp/entitlements.plist << EOF
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
xattr -cr "$APP_DIR"
codesign --force --deep --sign - --entitlements /tmp/entitlements.plist "$APP_DIR"

# Done
echo "[6/6] Build complete!"
echo ""
echo "=== Build Summary ==="
echo "App:     $APP_DIR"
echo "Version: $VERSION"
echo "Size:    $(du -sh "$APP_DIR" | cut -f1)"
echo ""
echo "To install, run:"
echo "  cp -r $APP_NAME.app /Applications/"
echo ""
echo "Or drag $APP_NAME.app to your Applications folder."
