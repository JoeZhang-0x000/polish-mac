#!/bin/bash
# Build Polish.app into ./build. Pass --install to copy it into /Applications.
# Signing: uses $SIGN_IDENTITY if set, else "Polish Local Signing" (created by
# scripts/setup_signing.sh) if present, else ad-hoc. An ad-hoc signature changes every
# build, so macOS treats each build as a new app and the Accessibility grant is lost.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Polish.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Polish"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Polish"

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Polish</string>
  <key>CFBundleDisplayName</key><string>Polish</string>
  <key>CFBundleIdentifier</key><string>app.polish.mac</string>
  <key>CFBundleExecutable</key><string>Polish</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Polish Local Signing"'; then
  IDENTITY="Polish Local Signing"
fi
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
if [ -z "$IDENTITY" ]; then
  echo "Tip: run ./scripts/setup_signing.sh once so the Accessibility grant survives rebuilds."
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x Polish 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Polish >/dev/null || break; sleep 0.3; done
  rm -rf /Applications/Polish.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Polish.app"
fi
