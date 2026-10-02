#!/usr/bin/env bash
# Builds build/Murmur.app from the Swift package.
#
#   scripts/build-app.sh            release build, ad-hoc signed
#   MURMUR_SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh
#
# macOS ties Accessibility and Microphone permission to the app's signature. Ad-hoc signatures
# change on every build, so you have to re-grant Accessibility after rebuilding. Signing with a
# stable identity (any Apple Development certificate, or a self-signed code-signing certificate
# from Keychain Access) avoids that.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${MURMUR_SIGN_IDENTITY:--}"
APP="build/Murmur.app"

swift build -c "$CONFIG" --product Murmur
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"

# Dynamic frameworks from binary targets (llama.framework) and SwiftPM resource bundles.
shopt -s nullglob
for framework in "$BIN"/*.framework; do cp -R "$framework" "$APP/Contents/Frameworks/"; done
for bundle in "$BIN"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
shopt -u nullglob

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Murmur" 2>/dev/null || true

# Every @rpath library the executable links must be inside the bundle.
missing=0
while read -r lib; do
  name="${lib#@rpath/}"
  if [[ ! -e "$APP/Contents/Frameworks/$name" ]]; then
    echo "missing from bundle: $lib" >&2
    missing=1
  fi
done < <(otool -L "$APP/Contents/MacOS/Murmur" | awk '/@rpath\// {print $1}')
[[ $missing == 0 ]] || exit 1

for framework in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign "$IDENTITY" "$framework"
done
codesign --force --sign "$IDENTITY" --identifier com.noahweiss.murmur "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
