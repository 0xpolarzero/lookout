#!/bin/bash
# Builds build/Lookout.app (a bundle is required for notifications and launch at login).
# VERSION=1.2.3 sets the bundle version; UNIVERSAL=1 builds for arm64 + x86_64 (used for releases).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.0-dev}"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Lookout
else
  swift build -c release
  BIN=.build/release/Lookout
fi
APP=build/Lookout.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lookout"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.polarzero.lookout</string>
  <key>CFBundleName</key><string>Lookout</string>
  <key>CFBundleDisplayName</key><string>Lookout</string>
  <key>CFBundleExecutable</key><string>Lookout</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signatures change with every build, so macOS forgets Accessibility access each time and the in-app
# updater can't tell a release is really ours. A stable code-signing certificate (default name "Lookout Dev",
# or SIGN_IDENTITY, which is then required) keeps both working across builds.
IDENTITY="${SIGN_IDENTITY:-Lookout Dev}"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
elif [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "Signing identity \"$SIGN_IDENTITY\" not found" >&2
  exit 1
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION)"
