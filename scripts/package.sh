#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
warpweb_bin=$(swift build -c release --show-bin-path)
warpweb_cli="$PWD/.build/cli"
mkdir -p "$warpweb_cli"
cp "$warpweb_bin/warpweb" "$warpweb_cli/warpweb"
ditto "$warpweb_bin/warpweb_warpweb.bundle" "$warpweb_cli/warpweb_warpweb.bundle"
codesign --force --sign - "$warpweb_cli/warpweb"
printf '%s\n' "$warpweb_cli/warpweb"
