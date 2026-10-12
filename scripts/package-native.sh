#!/bin/sh
# Build a review artifact, not an installed/default browser. Managed signing is
# deliberately separate: an ad-hoc entitlement does not grant Apple capability.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
warpweb_bin=$(swift build -c release --show-bin-path)
warpweb_app="$PWD/.build/native/warpweb.app"
mkdir -p "$warpweb_app/Contents/MacOS" "$warpweb_app/Contents/Resources"
cp packaging/Info.plist "$warpweb_app/Contents/Info.plist"
cp "$warpweb_bin/warpweb" "$warpweb_app/Contents/MacOS/warpweb"
ditto "$warpweb_bin/warpweb_warpweb.bundle" "$warpweb_app/Contents/Resources/warpweb_warpweb.bundle"
mkdir -p "$warpweb_app/Contents/Resources/Licenses"
cp LICENSE LICENSE-ASSETS.md LICENSE-ARTWORK ASSETS.md "$warpweb_app/Contents/Resources/Licenses"
codesign --force --sign - "$warpweb_app"
codesign --verify --strict "$warpweb_app"
"$warpweb_app/Contents/MacOS/warpweb" --native-status
printf 'Prepared development bundle: %s\n' "$warpweb_app"
printf 'No managed entitlement was applied. See packaging/README.md.\n'
