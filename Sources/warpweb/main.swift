import CWarpWeb
import AppKit
import Foundation
import WarpWebCore

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print("""
    Usage: warpweb [URL] [--url URL]
           warpweb --serve [--port PORT] [--url URL] [--session-file PATH]

    Displays a WebKit browser directly in a Warp terminal panel using Kitty graphics.
    Controls: Ctrl-L address, Alt-Left/Right history, Ctrl-F find, Ctrl-R reload, F1 help, Ctrl-Q quit.
    Click to focus, type to enter text, and use the mouse wheel to scroll.

    --pointer        Show the rendered mouse pointer (off by default; F8 toggles).
    --native-status  Report native browser/passkey capability without prompting.
    --set-homepage URL  Save the homepage and exit (default: Google, US English).
    --capture MODE    Page capture: auto (default), snapshot, or stream.
                      Auto uses stream with existing capture access, otherwise snapshot.
    --request-capture-access  Request macOS Screen Recording access, then exit.
    --scale NUMBER    Terminal render density: 1–3 (default: 1, terminal pixel size).
    --download-dir PATH  Save downloads here (default: ~/Downloads/warpweb).
    --diagnostics-file PATH  Save browser/input metadata for troubleshooting.
    --serve          Run the optional local HTML viewer instead of terminal graphics.
    --port PORT      HTML bridge port (default: 8768; requires --serve).
    --session-file   Save the HTML viewer URL (requires --serve).
    """)
    exit(0)
}
if args == ["--native-status"] {
    let data = try JSONSerialization.data(withJSONObject:NativeBrowserSupport.status(),options:[.prettyPrinted,.sortedKeys])
    print(String(decoding:data,as:UTF8.self)); exit(0)
}
if args == ["--request-capture-access"] {
    let allowed = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    print(allowed ? "Screen Recording access granted. Restart with --capture stream." : "Grant Screen Recording access in System Settings, then restart with --capture stream.")
    exit(allowed ? 0 : 1)
}
if args.first == "--set-homepage" {
    guard args.count == 2 else { fail("Expected --set-homepage URL") }
    do { try HomepageSettings().set(args[1]); print("Homepage: \(HomepageSettings().url)"); exit(0) }
    catch { fail("Expected an http(s) homepage URL") }
}
var captureMode: CaptureMode = .automatic
var serve = false
var pointerEnabled = false
var initialURL: String?
var sessionFile: String?
var diagnosticsFile: String?
var downloadDirectory: String?
var renderScale = 1.0
var port: UInt16 = 8768
var portSpecified = false
var index = 0
func fail(_ message: String) -> Never { fputs("warpweb: \(message)\nTry warpweb --help.\n", stderr); exit(2) }
while index < args.count {
    let arg = args[index]
    switch arg {
    case "--serve": serve = true
    case "--pointer": pointerEnabled = true
    case "--url", "--port", "--session-file", "--diagnostics-file", "--download-dir", "--scale", "--capture":
        index += 1
        guard index < args.count, !args[index].hasPrefix("--") else { fail("Missing value for \(arg)") }
        if arg == "--capture" { guard let mode = CaptureMode(rawValue:args[index]) else { fail("--capture must be auto, snapshot, or stream") }; captureMode = mode }
        else if arg == "--url" { initialURL = args[index] }
        else if arg == "--download-dir" { downloadDirectory = args[index] }
        else if arg == "--diagnostics-file" { diagnosticsFile = args[index] }
        else if arg == "--scale" { guard let value = Double(args[index]), value.isFinite, (1...3).contains(value) else { fail("--scale must be between 1 and 3") }; renderScale = value }
        else if arg == "--session-file" { sessionFile = args[index] }
        else { guard let value = UInt16(args[index]), value > 0 else { fail("Invalid port") }; port = value; portSpecified = true }
    default:
        guard !arg.hasPrefix("-"), initialURL == nil else { fail("Unknown or duplicate argument: \(arg)") }
        initialURL = arg
    }
    index += 1
}
if serve && captureMode == .stream { fail("--capture stream requires terminal mode") }
if !serve && (portSpecified || sessionFile != nil) { fail("--port and --session-file require --serve") }
if let url = initialURL, browserURL(url) == nil { fail("Expected an http(s) URL") }
if !serve && (isatty(STDIN_FILENO) != 1 || isatty(STDOUT_FILENO) != 1) { fail("Run in an interactive terminal panel, or pass --serve") }
let graphicsIDs = SessionGraphicsIDs(processID: Int(getpid()))
if !serve && warpweb_watchdog_start(UInt32(graphicsIDs.first), UInt32(graphicsIDs.second)) < 0 { fail("Cannot start session cleanup watchdog") }
let app = NSApplication.shared
app.appearance = NSAppearance(named: .darkAqua)
app.setActivationPolicy(.accessory)
let browser = Browser()
if let downloadDirectory { browser.downloadDirectory = URL(fileURLWithPath:(downloadDirectory as NSString).expandingTildeInPath,isDirectory:true) }
if !serve {
    do {
        let streamCapture = captureMode.usesStream(isServing:serve, captureAccess:CGPreflightScreenCaptureAccess)
        let terminal = try TerminalBrowser(browser: browser, diagnosticsFile: diagnosticsFile, renderScale:renderScale, streamCapture:streamCapture, graphicsIDs:graphicsIDs, pointerEnabled:pointerEnabled)
        try browser.navigate(initialURL ?? HomepageSettings().url)
        try terminal.start()
        app.run()
    } catch { fail(String(describing: error)) }
    exit(0)
}
let host = "127.0.0.1:\(port)"
let origin = "http://\(host)"
let prefix = "/s/\(UUID().uuidString.lowercased())/"
let viewerURL = origin + prefix
let resources = Bundle.module.resourceURL!.appendingPathComponent("Resources")
let staticFiles = ["": ("index.html", "text/html; charset=utf-8"), "viewer.js": ("viewer.js", "text/javascript"), "style.css": ("style.css", "text/css"), "fixture.html": ("fixture.html", "text/html; charset=utf-8"), "fixture.js": ("fixture.js", "text/javascript")]
let server = try Server(port: port) { request in
    guard request.headers["host"] == host else { return .json(["error": "Invalid host"], status: 403) }
    if let source = request.headers["origin"], source != origin { return .json(["error": "Cross-origin requests are not allowed"], status: 403) }
    guard request.path.hasPrefix(prefix) else { return .json(["error": "Session URL required"], status: 404) }
    let route = String(request.path.dropFirst(prefix.count)).components(separatedBy: "?")[0]
    if request.method == "POST", route == "command" {
        guard request.headers["content-type"]?.hasPrefix("application/json") == true else { return .json(["error": "JSON required"], status: 415) }
        return browser.command(request.body)
    }
    guard request.method == "GET" else { return .json(["error": "Method not allowed"], status: 405) }
    if route == "state" { return .json(browser.status()) }
    if route == "frame" { return await browser.frame() }
    guard let (file, type) = staticFiles[route], let data = try? Data(contentsOf: resources.appendingPathComponent(file)) else { return .json(["error": "Not found"], status: 404) }
    return Response(type: type, data: data)
}
if let path = sessionFile {
    try PrivateFile.write(Data((viewerURL + "\n").utf8), to: URL(fileURLWithPath: path))
}
try browser.navigate(initialURL ?? HomepageSettings().url)
print("warpweb — WebKit browser bridge\n\(viewerURL)")
fflush(stdout)
app.run()
