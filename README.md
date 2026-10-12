# WarpWeb

**A WebKit browser inside your terminal.**

WarpWeb renders an interactive browser into a Warp terminal panel using the Kitty graphics protocol. Open tabs, follow links, fill forms, play supported HTML5 video and navigate with the mouse or keyboard—without sending the page to a remote rendering service.

Experimental macOS software · Swift 6 · MIT source code

## Quick start

You need **macOS 14 or later**, a graphical login, a Swift 6 toolchain and a terminal with Kitty graphics support. Warp is the primary target; compatibility with every graphics-capable terminal is not promised.

```sh
git clone https://github.com/mmingo-director-of-ai/warpweb.git
cd warpweb
./scripts/install.sh
~/bin/warpweb https://www.swift.org
```

The installer builds locally and links `~/bin/warpweb` to this checkout's `.build/cli/warpweb`. Keep the checkout in place. It refuses to replace an unrelated existing installation. Add `~/bin` to your shell's PATH if needed.

In Warp, enable **Mouse Reporting** and **Scroll Reporting**. Holding Shift sends mouse input to the terminal instead of the browser.

## What works

- Tabs, an address bar, navigation controls, menus and a dark browser shell.
- Native WebKit page rendering and input, selection, paste, find and zoom.
- Forms, in-page dialogs, explicitly selected uploads and downloads.
- Persistent cookies and site storage in WarpWeb's own profile.
- HTML5 playback, including tested embedded players; DRM and separate fullscreen surfaces remain site-dependent.
- Automatic capture selection, private shared-memory transport where supported and PNG fallback.

| Shortcut | Action |
| --- | --- |
| Ctrl-L | Address bar |
| Ctrl-T / Ctrl-W | New tab / close tab |
| Ctrl-R | Reload |
| Ctrl-F | Find |
| F1 | Full shortcut help |
| Ctrl-Q / Ctrl-C | Quit and restore terminal |

See [the complete guide](docs/usage.md) for controls, homepage settings, rendering details and diagnostics.

## Capture and performance

`--capture auto` checks existing macOS Screen Recording access without prompting. If allowed, it attempts window-only streaming; otherwise it uses WebKit snapshots. **Actual capture can still be denied after a successful permission check.** Stream failures fall back to snapshots and may reduce responsiveness. Streaming targets 60 fps and snapshots 30 fps during activity; these are targets, not guaranteed delivery rates.

```sh
warpweb --capture snapshot https://example.com
warpweb --capture stream https://example.com
warpweb --request-capture-access
```

The last command requests access only when the preflight says it is missing; it is not a complete stream test. For a permission mismatch, review the app/terminal's Screen Recording access in macOS settings and restart. Development binaries are ad-hoc signed; permission persistence across rebuilds is not guaranteed. There is no permission bypass.

## Privacy and security

Remote websites retain their normal network access. Capture is limited to WarpWeb's own page window; the terminal does not receive your desktop. Browser chrome and web content use separate WebKit views. Uploads require an explicit local-file selection; downloads are saved under `~/Downloads/warpweb` by default.

This is **not Safari.app**: Safari profiles, passwords, extensions and tabs are not shared. WarpWeb is a desktop browser process, not an isolation boundary against malicious local programs or a replacement for macOS/WebKit security updates.

The optional `--serve` viewer binds only to `127.0.0.1`, validates Host and Origin, and uses an unpredictable session URL. Treat that URL as a credential: do not publish, proxy or tunnel it. Diagnostics are opt-in, written with owner-only permissions, and can contain sensitive titles and full URLs. Inspect them before sharing.

Read [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## Build and verify

The main check needs Swift 6, Node.js, Python 3 and Xcode command-line tools. The terminal smoke test also needs `ffmpeg` and Pillow. These are development tools, not third-party runtime packages.

```sh
./scripts/check.sh
python3 scripts/terminal-smoke.py
python3 scripts/transport-smoke.py
mkdir -p run
./scripts/run.sh --serve --session-file "$PWD/run/session.url"
# In another terminal, from the checkout:
python3 scripts/smoke.py
```

The PTY harness validates protocol, input and captured pixels. It does not verify physical presentation or latency in Warp. Screen-capture permission tests and visual checks require an interactive Mac; CI does not certify those paths. See [verification details](docs/usage.md#verification).

## Limits

IME composition, OS drag-and-drop, passkeys/system authentication UI, DRM, and full Safari compatibility are not verified. Downloads can stop when their tab closes. A graphical login is required. Stream fallback and capture-permission behavior remain active areas of development. No signed or notarized binary release is offered here.

## Contribute and license

Contributions go through [pull requests](CONTRIBUTING.md). Source code is [MIT](LICENSE); Kairo artwork has [separate branding terms](LICENSE-ASSETS.md). See [asset provenance](ASSETS.md). WarpWeb is independent of Warp and Apple and does not imply their endorsement.
