#!/usr/bin/env bash
# Builds "Blender Play.app" (formerly Loveploy) (universal: Apple Silicon + Intel) into ./dist.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Blender Play.app"

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

# Signing. macOS ties permissions (microphone, Keychain "Always Allow", Accessibility,
# notifications) to the app's signing identity. An ad-hoc signature is new on every build, so
# each update asked for everything again. With a certificate (SIGN_IDENTITY, or one named
# "Blender Play" in the Keychain) the identity stays the same and permissions are kept.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # By fingerprint: a self-signed certificate isn't "valid" for find-identity -v.
    IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"Blender Play/ {print $2; exit}')"
fi
if [[ -n "$IDENTITY" ]]; then
    echo "Firmando con: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "Sin certificado: firma ad hoc (macOS volverá a pedir permisos con cada versión)."
    codesign --force --deep --sign - "$APP"
fi

(cd dist && rm -f BlenderPlay.zip && ditto -c -k --keepParent "Blender Play.app" BlenderPlay.zip)
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Loveploy || true
    # Same app as Loveploy (same settings and data), under its new name.
    rm -rf /Applications/Loveploy.app "/Applications/Blender Play.app"
    cp -R "$APP" /Applications/
    echo "Instalado en /Applications/Blender Play.app"
    open "/Applications/Blender Play.app"
fi
