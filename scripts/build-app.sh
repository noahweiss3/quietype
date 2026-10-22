#!/usr/bin/env bash
# Builds build/Quietype.app from the Swift package: compiles the Quietype executable, copies in the
# llama.cpp framework, any resource bundles and the license notices, checks that every framework
# the app links is inside the bundle, then code-signs it.
#
# Usage:
#   scripts/build-app.sh
#   CONFIG=debug scripts/build-app.sh
#   QUIETYPE_SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh
#
# Environment:
#   CONFIG                   SwiftPM build configuration: release (default) or debug.
#   QUIETYPE_SIGN_IDENTITY   Code-signing identity. Defaults to "-", an ad-hoc signature.
#
# macOS ties Accessibility and Microphone permission to the app's signature. An ad-hoc signature
# changes on every build, so you have to grant Accessibility again after each rebuild. Signing
# with a stable identity (any Apple Development certificate, or a self-signed code-signing
# certificate made in Keychain Access) avoids that.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${QUIETYPE_SIGN_IDENTITY:--}"
APP="build/Quietype.app"
EXECUTABLE="$APP/Contents/MacOS/Quietype"
RPATH="@executable_path/../Frameworks"
# Read from Info.plist so the bundle identifier is defined in one place.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"

swift build -c "$CONFIG" --product Quietype
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp "$BIN/Quietype" "$EXECUTABLE"

# Dynamic frameworks from binary targets (llama.framework) and SwiftPM resource bundles.
shopt -s nullglob
for framework in "$BIN"/*.framework; do cp -R "$framework" "$APP/Contents/Frameworks/"; done
for bundle in "$BIN"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
shopt -u nullglob

# The executable loads its frameworks through @rpath, so it has to search the bundle's Frameworks
# folder. install_name_tool refuses to add an rpath that's already there, so add it only when it's
# missing; any other failure stops the build.
rpaths="$(otool -l "$EXECUTABLE" | awk '$1 == "path" { print $2 }')"
if ! grep -qxF "$RPATH" <<<"$rpaths"; then
  install_name_tool -add_rpath "$RPATH" "$EXECUTABLE"
fi

# Every @rpath library the executable links must be inside the bundle.
missing=0
while read -r lib; do
  name="${lib#@rpath/}"
  if [[ ! -e "$APP/Contents/Frameworks/$name" ]]; then
    echo "missing from bundle: $lib" >&2
    missing=1
  fi
done < <(otool -L "$EXECUTABLE" | awk '/@rpath\// {print $1}')
[[ $missing == 0 ]] || exit 1

for framework in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign "$IDENTITY" "$framework"
done
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
