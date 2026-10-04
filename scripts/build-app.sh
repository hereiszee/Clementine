#!/bin/bash
# Builds Clementine.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Clementine"

APP="build/Clementine.app"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
cp "$BIN" "$APP/Contents/MacOS/Clementine"
cp Resources/Info.plist "$APP/Contents/Info.plist"

for size in 16 32 128 256 512; do
  "$BIN" --render-icon "$size" "build/AppIcon.iconset/icon_${size}x${size}.png"
  "$BIN" --render-icon "$((size * 2))" "build/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it locally.
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application "Clementine" to quit' >/dev/null 2>&1 || true
  rm -rf /Applications/Clementine.app
  cp -R "$APP" /Applications/
  open /Applications/Clementine.app
  echo "Installed to /Applications and launched — look for the 🍊 slice in your menu bar."
fi
