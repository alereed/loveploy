#!/usr/bin/env bash
# Builds Loveploy.app (universal: Apple Silicon + Intel) into ./dist.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Loveploy.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Loveploy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loveploy"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS runs it locally. Downloaded builds still need
# right click → Open the first time (they aren't notarized).
codesign --force --deep --sign - "$APP"

(cd dist && rm -f Loveploy.zip && ditto -c -k --keepParent Loveploy.app Loveploy.zip)
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Loveploy.app
    cp -R "$APP" /Applications/
    echo "Instalado en /Applications/Loveploy.app"
    open /Applications/Loveploy.app
fi
