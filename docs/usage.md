# WarpWeb usage and implementation

An interactive WebKit browser rendered inside a Warp terminal panel, with HTML tabs, toolbar, menus, dialogs, and footer. Kairo is the app avatar.

## Install and run

Requires macOS 14+, a graphical login, Swift 6, and Kitty graphics support.

```sh
./scripts/install.sh
warpweb https://www.swift.org
```

**Enable Mouse Reporting in Warp** using the command palette, or Settings → Features → Terminal. If the palette says “Enable mouse reporting”, clicks are currently blocked by Warp. Scroll Reporting must also be enabled for the wheel. Holding Shift routes mouse events to Warp instead of the browser. The footer distinguishes **Mouse movement received** from button press/release counts; movement alone does not confirm clicks arrive.

The installer keeps the binary and resources under this checkout's `.build/cli/` and links `~/bin/warpweb` to them. The checkout must remain in place.

## Browser controls

- Click links and controls, hover, drag sliders/select text, and scroll nested elements and frames.
- Type into fields, Tab/Shift-Tab between controls, use modified arrow keys for selection, and paste multiline text with bracketed paste.
- Use the HTML address bar, back/forward/reload buttons, tab strip, and browser menu.
- Right-click for browser actions; link menus offer opening a new tab, copying the URL, and downloading the link. Page-owned context menus retain their own handling.
- Browser menu: copy/cut/paste, find in page, zoom, and stop loading.
- Alerts, confirmations, text prompts, and HTTP Basic/Digest credentials appear inside the rendered view. Password fields are masked.
- File uploads ask for a local absolute path (or `~/…`) inside the browser; multiple selection accepts one path per line.
- Downloads go to `~/Downloads/warpweb`, or `--download-dir PATH`. Existing files are not overwritten.
- Popup links open tabs. Cookies and WebKit site storage persist in warpweb's own session.

| Shortcut | Action |
| --- | --- |
| Ctrl-L | Focus/select the address |
| Ctrl-T / Ctrl-W | New tab / close tab |
| Alt-Left / Alt-Right | Back / forward (Ctrl-B also goes back) |
| Ctrl-R / F5 | Reload |
| Escape | Dismiss a menu/dialog or stop loading |
| Ctrl-F | Find in page |
| Ctrl-G / F3 / Shift-F3 | Find next / next / previous |
| Ctrl-PageUp / Ctrl-PageDown | Previous / next tab |
| Alt-+ / Alt-− / Alt-0 | Zoom in / out / reset |
| F6 | Focus/select the address |
| F8 | Toggle the high-contrast pointer |
| F1 | Shortcut help |
| Ctrl-A | Select all in the focused field |
| Ctrl-V / Ctrl-X | Paste / cut |
| Escape | Dismiss a page dialog or leave address entry |
| Ctrl-Q or Ctrl-C | Quit and restore the terminal |

Loading tabs and a progress bar show navigation activity; Reload becomes Stop during loading. The footer shows focus, zoom, and hovered link destinations. The rendered pointer is off by default. Start with `warpweb --pointer` to enable it, or toggle it with F8 during a session; it does not require a new HTML snapshot for every page movement. Text fields receive a visible focus outline.

Warp may intercept shortcuts before the app receives them. Its browser menu provides mouse-accessible alternatives.

## Rendering and input

Each invocation runs in its own process with separate WebKit windows, capture, and terminal image IDs. Sessions use warpweb's shared persistent profile; saved cookies load in new sessions. WebKit does not guarantee immediate login/logout cookie synchronization between already-running processes; restart a peer session to pick up saved changes. A per-session watchdog restores terminal settings and removes outstanding shared-memory frames after a renderer crash, and terminates the renderer if its terminal closes—even if the renderer is hung. WebKit owns its helper-process lifecycle; warpweb never kills helpers belonging to another session. This is not Safari.app cookie or Passwords sharing.

The full panel is one image canvas. An independent, trusted HTML WebKit view renders the app chrome; the remote page occupies its own WebKit view. Frames default to the pixel dimensions reported by the terminal (`--scale 1`) and are sent through Kitty graphics without changing the logical page layout. The previous 2× default encoded and transferred four times as many pixels per frame. Use `--scale 2` or `--scale 3` for optional supersampling at a higher frame cost; output is capped at 7680×4320 pixels. Screenshots are composed directly off the input thread. Local terminals that acknowledge Kitty shared-memory support receive lossless RGBA frames through private, short-lived memory objects, avoiding PNG encoding and bulk terminal traffic. Each frame is acknowledged before the previous image is deleted, including the PNG path. Transient capture failures retain the last valid image. Unsupported or unresponsive shared-memory transport falls back to PNG streaming. Opaque PNG frames use up to eight bounded compression workers, preserving RGBA pixels and the color profile. Translucent frames or encoder failures use the platform PNG encoder. The unchanged HTML chrome is cached between frames. Snapshots target 30 fps during input or media playback, streams target 60 fps, and idle rendering targets 10 fps; achieved rates depend on the page and terminal throughput. AppKit pointer/keyboard events are delivered directly to these owned views, without global input injection or activating an external browser window. One coordinate transform covers page and toolbar input.

Double-click selects a word; triple-click selects a line/paragraph using WebKit’s native selection. Wheel reports move 40 CSS pixels in eased steps, with bounded pending movement and immediate direction reversal.

HTML5 video remains in WebKit with its original playback controls and audio path. Media detection in isolated script worlds keeps rendering active for main-frame and cross-origin embedded players. The test verifies changing video pixels, play/pause/seek, and an embedded player; protected/DRM and other accelerated content remain site-dependent.

Dropdowns expand into in-page lists so options appear in snapshots. Kairo's existing avatar is bundled locally; no external image service is used.

This embeds WebKit, not Safari.app. Safari tabs, cookies, extensions, passwords, and profiles are not shared.

## Troubleshooting

```sh
mkdir -p run
warpweb --diagnostics-file "$PWD/run/browser-state.json" https://example.com
```

Capture defaults to `auto`: terminal sessions attempt continuous window streaming when the macOS permission preflight succeeds, otherwise they use snapshots. A successful preflight does not guarantee stream startup; macOS can still deny it and trigger snapshot fallback. Automatic selection never requests permission. Use `--capture snapshot` to force snapshots, or explicitly select streaming with:

```sh
warpweb https://www.youtube.com --capture stream --diagnostics-file /tmp/warpweb-stream.json
```

This uses ScreenCaptureKit for only warpweb's selected page window, with read-locked BGRA pixel buffers retained directly by Core Graphics, avoiding an intermediate GPU render/readback. Unsupported buffer formats use Metal-backed Core Image conversion. Capture permission is checked when opening/restarting a stream; stream errors trigger snapshot fallback. Transient connection/start/internal errors retry after 2, 4 and 8 seconds, with at most three attempts until a stream has stayed healthy for 30 seconds. Permission denial, missing entitlements and intentional stops do not retry. Diagnostics retain the last failure and report pending recovery. Each helper window has a transparent 2-point border. Only a 1×1-point corner of that border overlaps the bottom-right edge of the rightmost display; all WebKit pixels are off-display. This keeps window capture active without placing the page on the desktop. Capture crops out the border. Windows are repositioned on resize and display-layout changes. This is window-backed capture, not a headless WebKit API. The HTML toolbar remains cached WebKit snapshots. Streaming targets 60 fps during interaction/playback or recent source updates (including CSS/canvas animation); actual delivery depends on capture, conversion and terminal throughput. The latest surface replaces older frames instead of building a queue. On PNG transport during interaction/playback, the next frame is prepared while the terminal receives the current one. Lookahead is limited to one frame; preparation is delayed using the previous transfer cost to reduce waiting-frame age. Resize/transport changes, new scroll gestures or direction reversals, and frames waiting over 150 ms invalidate the prepared result. Input interrupts render pacing immediately. Scroll updates use absolute timer deadlines and the same elapsed-time accumulator immediately before capture; fractional movement is retained so extra capture updates cannot accelerate scrolling. New gestures and direction reversals apply an immediate first step. Image uploads remain serialized and acknowledged before deleting the previous image. Tab changes and resizing restart the page stream; captured windows are retained until their stream stops, and quitting stops capture. Snapshot capture remains the fallback on capture errors, missing permission, or stalled media frames. The optional `--serve` bridge always uses snapshots, including with `--capture auto`.

To enable streaming when capture access has not been granted, run `warpweb --request-capture-access`, grant the requested access in macOS, and restart. Automatic selection checks existing permission once at startup; only this explicit command requests access. The experimental mode never captures the desktop or another application's window. Stream resolution depends on the source window's backing resolution; requesting larger output can upscale it and does not guarantee additional detail. `helperPagePixelsOnDisplay` detects accidental page/display overlap across all helper windows. `captureConversion` reports `direct-bgra` or the `core-image` fallback. `captureBackend` identifies the actual backend, `captureFallback` explains fallback, and `captureFrames`/`captureFrameAgeMilliseconds` distinguish new source frames from repeated output. A static page may legitimately retain its last frame. `renderPipeline` identifies the lookahead build, and `imageEncoder` reports `parallel-png`, `platform-png`, or `raw-rgba`. `preparationMilliseconds` measures capture plus composition/encoding; `frameAgeMilliseconds` measures preparation start to image acknowledgment (not physical screen presentation). Capture/encoding timings refer to the delivered preparation, even when the next frame is being prepared. `frameMilliseconds` measures the output-loop iteration, which overlaps preparation in pipeline mode, so it is no longer the sum of all stages. Run `WARPWEB_TEST_CAPTURE=stream WARPWEB_EXPECT_CAPTURE=stream WARPWEB_TEST_STREAM_VIDEO=1 python3 scripts/terminal-smoke.py` for the sustained stream test (requires capture permission).

If another live session owns the requested diagnostics path, the new session writes a PID-suffixed file and prints that path. Diagnostics include `processPID`, `watchdogPID`, and `graphicsIDs`. Small `.lock` files remain beside diagnostics; their locks release automatically when the process exits.

The optional file records page title/URL, viewport geometry, tabs, dialog type, and mouse event counts/coordinates, terminal dimensions, and the last 32 button presses/releases. It does not record typed text or password values. A page can itself put sensitive text in its title or URL, so inspect the file before sharing it. If `pointerEvents` remains zero, enable Warp's Mouse Reporting and focus the panel. Compare `pointerPresses`, `pointerReleases`, and `recentClicks` when movement arrives but clicks fail. `error` reports WebKit snapshot failures. `renderWidth`/`renderHeight` show delivered resolution, `frameMilliseconds` measures the output-loop iteration, `captureMilliseconds`/`encodeMilliseconds`/`transferMilliseconds` break down the stages, `transport` shows the negotiated image path, `transportFallback` records why shared memory was rejected or timed out, `lastGraphicsReply` records the latest terminal graphics response, and `deliveryFPS`/`deliveryIntervalMedianMilliseconds`/`deliveryIntervalP95Milliseconds`/`deliveryIntervalMaxMilliseconds` summarize the last 120 acknowledged delivery intervals (not physical display refresh), and `mediaPlaying` reports active playback. Restart an already-running warpweb process after installing an update.

## Verification

The terminal smoke test additionally requires `ffmpeg` and Python Pillow to generate a local video fixture and inspect captured pixels.

```sh
./scripts/check.sh
python3 scripts/terminal-smoke.py
python3 scripts/transport-smoke.py
./scripts/run.sh --serve --session-file "$PWD/run/session.url"
# In another terminal:
python3 scripts/smoke.py
```

The PTY test drives the actual CLI and WebKit: full-resolution frames, native input, HTML controls, forms, dropdowns, nested scrolling, cross-origin iframe input, tabs/popups, right-click link menus, paste/selection, find, dialogs, uploads, downloaded file contents, HTTP authentication, double/triple-click selection, eased scrolling, main-frame/embedded video playback, resize, and terminal restoration. To test PNG fallback, set `WARPWEB_TEST_TRANSPORT=png`. Test default automatic selection with `WARPWEB_TEST_CAPTURE=default WARPWEB_EXPECT_CAPTURE=stream python3 scripts/terminal-smoke.py` on a machine with capture permission; use `WARPWEB_EXPECT_CAPTURE=snapshot` without permission. The regular gate explicitly exercises snapshot mode for deterministic coverage. Captured PNGs stay in ignored `run/`. It emulates Kitty replies; it does not visually inspect Warp itself. Add `WARPWEB_TEST_ACK_DELAY=0.035` to the PNG sustained stream test to simulate terminal backpressure, and `WARPWEB_TEST_BENCHMARK_FILE=run/benchmark.json` to save delivery and latency measurements. The sustained PNG stream benchmark can require `WARPWEB_EXPECT_ENCODER=parallel-png` and `WARPWEB_EXPECT_CONVERSION=direct-bgra`. `WARPWEB_TEST_CAPTURE_RECOVERY=1` with a debug binary injects one connection-interrupted delegate error and verifies snapshot fallback followed by a real stream restart; fault injection is excluded from release binaries. `WARPWEB_TEST_SCALE=2` exercises explicit supersampling; without it the harness tests the CLI’s 1× default. `WARPWEB_TEST_SCROLL=1` measures idle-input-to-changed-page-pixels latency and continuous-scroll frame gaps in an owned PTY (use PNG transport and streaming for comparison). It does not measure physical Warp display latency. `WARPWEB_TEST_ANIMATION=1` tests a CSS animation after input becomes idle, without a media-playing flag. On heavily loaded machines, `WARPWEB_TEST_TIMEOUT=45` increases the transport test case deadline without changing its assertions (default 15 seconds). Run transport tests with `WARPWEB_TEST_CAPTURE=stream` to exercise delayed acknowledgments, resize and quit while lookahead is active.

The browser shell defaults to dark mode, and embedded pages receive the native dark appearance preference (`prefers-color-scheme: dark`). Sites retain control of their own colors and theme settings.

## Current limits

This remains an experimental browser, not complete Safari parity. Terminal mouse coordinates have cell precision, and frame delivery depends on page/terminal throughput. IME composition, OS file drag-and-drop, Safari extensions/password integration, passkey/system permission dialogs, and DRM media are not implemented or verified. Ordinary and embedded HTML5 video are tested; protected video, full-screen video windows, and other accelerated surfaces are not guaranteed. Site compatibility must be tested individually; “every page” is not a guarantee. Downloads may be interrupted if their tab is closed. Dropdown adaptation can affect custom select styling.

The helper WebKit windows are nearly transparent and ignore physical mouse input; a graphical login remains necessary. Unsupported graphics terminals exit with restored settings.

## Optional HTML bridge

`warpweb --serve --port 8768 --session-file PATH` retains the earlier loopback HTML viewer. The full browser shell and tab/dialog workflows belong to the default terminal mode. The bridge binds only to `127.0.0.1`, uses a random session path, checks Host/Origin, and bounds requests. Do not publish or tunnel its session URL: it controls that browsing session.

## References

- [Warp mouse reporting](https://docs.warp.dev/terminal/more-features/full-screen-apps)
- [Warp Kitty graphics implementation](https://github.com/warpdotdev/warp/blob/master/crates/warp_terminal/src/model/kitty.rs)

Warpweb places Kitty images at `z=-1` to avoid Warp’s foreground image hit-testing bug ([#15882](https://github.com/warpdotdev/warp/issues/15882), [upstream fix](https://github.com/warpdotdev/warp/pull/15883)). Full-screen foreground images can otherwise receive movement while swallowing button presses and releases.

### Homepage

With no URL argument, warpweb opens Google with US/English preferences (`https://www.google.com/?hl=en&gl=us`). An explicit URL always takes precedence. New tabs open the saved homepage. Use the HTML browser menu’s **Home** and **Set homepage…** controls, or persist a homepage without launching the browser:

```sh
warpweb --set-homepage 'https://www.google.com/?hl=en&gl=us'
```

The preference is stored in the macOS defaults domain `ai.quandrylabs.warpweb`. The optional HTML bridge uses the same startup homepage.

### Native browser credentials

`warpweb --native-status` reports the installed binary's actual browser passkey entitlement and access state without prompting. Apple Passwords/Touch ID AutoFill for arbitrary websites is not integrated; the status command reports that separately from passkey capability. Passkeys and Apple Passwords AutoFill are not interchangeable. Native authentication UI presentation is not yet validated. See [native browser preparation](../packaging/README.md) for the development app bundle, Apple provisioning requirements and remaining work.

Concurrent-session and crash regression (uses owned PTYs and local fixtures):

```sh
python3 scripts/session-smoke.py .build/out/Products/Release/warpweb
```
