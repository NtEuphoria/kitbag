#!/bin/zsh
# Builds Kitbag.app and Kitbag.dmg into ./dist
set -euo pipefail
cd "$(dirname "$0")"
APP=dist/Kitbag.app
rm -rf dist build && mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Icon
swift make_icon.swift build/icon.png
ICONSET=build/Kitbag.iconset; mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/Kitbag.icns"

# Binary (universal: Apple Silicon + Intel)
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 \
    Sources/*.swift -o build/Kitbag-$arch
done
lipo -create build/Kitbag-arm64 build/Kitbag-x86_64 -output "$APP/Contents/MacOS/Kitbag"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Kitbag</string>
  <key>CFBundleDisplayName</key><string>Kitbag</string>
  <key>CFBundleIdentifier</key><string>app.kitbag.modmanager</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>Kitbag</string>
  <key>CFBundleIconFile</key><string>Kitbag</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

codesign --force --deep -s - "$APP"

# DMG with an Applications shortcut for drag-to-install
mkdir -p build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname Kitbag -srcfolder build/dmg -ov -format UDZO dist/Kitbag.dmg >/dev/null
echo "Built $APP and dist/Kitbag.dmg"
