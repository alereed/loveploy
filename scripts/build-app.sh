#!/usr/bin/env bash
# Builds Loveploy.app (universal: Apple Silicon + Intel) into ./dist.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Loveploy.app"

# One build per architecture, joined with lipo: a single multi-arch build goes through
# Xcode's build system, which doesn't run SwiftTerm's build plugin.
BINS=()
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx15.0"
    swift build -c release --triple "$TRIPLE"
    BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/Loveploy")
done
mkdir -p dist
BIN=dist/Loveploy-universal
lipo -create "${BINS[@]}" -output "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loveploy"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself.
"$APP/Contents/MacOS/Loveploy" --export-iconset dist/Loveploy.iconset
iconutil -c icns dist/Loveploy.iconset -o "$APP/Contents/Resources/Loveploy.icns"
rm -rf dist/Loveploy.iconset "$BIN"

# Ad-hoc signature so macOS runs it locally. Downloaded builds still need
# right click → Open the first time (they aren't notarized).
codesign --force --deep --sign - "$APP"

(cd dist && rm -f Loveploy.zip && ditto -c -k --keepParent Loveploy.app Loveploy.zip)
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Loveploy || true
    rm -rf /Applications/Loveploy.app
    cp -R "$APP" /Applications/
    echo "Instalado en /Applications/Loveploy.app"
    open /Applications/Loveploy.app
fi
