#!/bin/zsh
# Builds "HDL Viewer.app" into ./build.   Usage: ./build_app.sh [--install]
#   --install   also copies the app to ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HDL Viewer"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ Compiling (release)…"
swift build -c release --build-system native 2>&1 | grep -E "error: |Build complete" || true
BIN="$(swift build -c release --build-system native --show-bin-path 2>/dev/null)/HDLViewer"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HDLViewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f examples/counter.vcd ]] && cp examples/counter.vcd "$APP/Contents/Resources/"

echo "▸ Rendering icon…"
ICON_TMP="$BUILD_DIR/icon"
rm -rf "$ICON_TMP"; mkdir -p "$ICON_TMP/AppIcon.iconset"
swift Scripts/make_icon.swift "$ICON_TMP/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_TMP/icon_1024.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICON_TMP/icon_1024.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/$APP_NAME.app" || true
  echo "✓ Installed to ~/Applications/$APP_NAME.app"
else
  echo "✓ Built $APP"
fi
