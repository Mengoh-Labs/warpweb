#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
install_dir=${1:-"$HOME/bin"}
warpweb_target="$PWD/.build/cli/warpweb"
warpweb_link="$install_dir/warpweb"
if [ -e "$warpweb_link" ] || [ -L "$warpweb_link" ]; then
    if [ ! -L "$warpweb_link" ] || [ "$(readlink "$warpweb_link")" != "$warpweb_target" ]; then
        printf 'Refusing to replace existing %s\n' "$warpweb_link" >&2
        exit 1
    fi
fi
./scripts/package.sh
mkdir -p "$install_dir"
if [ ! -L "$warpweb_link" ]; then ln -s "$warpweb_target" "$warpweb_link"; fi
printf 'Installed %s -> %s\n' "$warpweb_link" "$warpweb_target"
