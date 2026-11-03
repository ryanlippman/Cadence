#!/bin/bash
# Builds a release Cadence.app into ./build/
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="build/Cadence.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cadence" "$APP/Contents/MacOS/Cadence"
cp -R "$BIN/Cadence_CadenceCore.bundle" "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Cadence</string>
  <key>CFBundleDisplayName</key><string>Cadence</string>
  <key>CFBundleIdentifier</key><string>app.cadence.focus</string>
  <key>CFBundleExecutable</key><string>Cadence</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Piano samples: Salamander Grand Piano by Alexander Holm, CC BY 3.0.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "codesign skipped"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
