#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test
swift build -c release
node --check Sources/warpweb/Resources/viewer.js
node --check Sources/warpweb/Resources/fixture.js
node --check Sources/warpweb/Resources/controls.js
node --check Sources/warpweb/Resources/context.js
node --check Sources/warpweb/Resources/media.js
node --check Sources/warpweb/Resources/feedback.js
python3 scripts/check-resources.py
node scripts/chrome-state-smoke.js
node scripts/feedback-state-smoke.js

# Exercise allocation bounds, noisy pixels, all PNG CRCs and lossless inflate.
xcrun clang -O1 -g -fsanitize=address,undefined -I Sources/CWarpWeb/include Sources/CWarpWeb/FastPNG.c scripts/png-smoke.c -lz -o .build/png-smoke
.build/png-smoke
