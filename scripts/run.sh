#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p run
swift build
warpweb_bin=$(swift build --show-bin-path)
exec "$warpweb_bin/warpweb" "$@"
