import AppKit
import WebKit
import WarpWebCore

@MainActor final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    let window: NSWindow
    var errorMessage = ""
    var cursorKind = "default", focusArea = "Page", hoverURL = ""
    private var requestedURL: String?
    var playingMediaFrames: [String: Bool] = [:]
    var hasPlayingVideo: Bool { playingMediaFrames.values.contains(true) }
    var snapshotBusy = false
    var clicks = PointerClicks()
    var pressedClickCount = 1
    var scrollMotion = ScrollMotion()
    var scrollTask: Task<Void, Never>?
    var scrollPoint = NSPoint.zero
    var scrollClock = 0.0
    var dialogHandler: ((BrowserDialog) async -> String?)?
    var closeHandler: (() -> Void)?
    var contextHandler: ((String?) -> Void)?
    var popupHandler: ((WKWebViewConfiguration) -> WKWebView?)?
    var downloadDirectory: URL?

    init(configuration supplied: WKWebViewConfiguration? = nil) {
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.websiteDataStore = .default()
        if let url = Bundle.module.url(forResource: "controls", withExtension: "js", subdirectory: "Resources"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let contextWorld = WKContentWorld.world(name:"warpweb-context")
        if let url = Bundle.module.url(forResource:"context",withExtension:"js",subdirectory:"Resources"), let script = try? String(contentsOf:url,encoding:.utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:false,in:contextWorld))
        }
        configuration.applicationNameForUserAgent = "warpweb/0.1"
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720), configuration: configuration)
        window = BrowserWindow(contentRect: NSRect(x: 40, y: 40, width: 1104, height: 724), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        view.configuration.userContentController.add(WeakMessageHandler(self),contentWorld:contextWorld,name:"pageContext")
        let mediaWorld = WKContentWorld.world(name:"warpweb-media")
        view.configuration.userContentController.add(WeakMessageHandler(self),contentWorld:mediaWorld,name:"mediaState")
        if let url = Bundle.module.url(forResource:"media",withExtension:"js",subdirectory:"Resources"),
           let script = try? String(contentsOf:url,encoding:.utf8) {
            view.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,
                forMainFrameOnly:false,in:mediaWorld))
        }
        let feedbackWorld = WKContentWorld.world(name:"warpweb-feedback")
        view.configuration.userContentController.add(WeakMessageHandler(self),contentWorld:feedbackWorld,name:"pageFeedback")
        if let url = Bundle.module.url(forResource:"feedback",withExtension:"js",subdirectory:"Resources"),
           let script = try? String(contentsOf:url,encoding:.utf8) {
            view.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,
                forMainFrameOnly:false,in:feedbackWorld))
        }
        // Transparent padding supplies an on-display capture anchor; all WebKit
        // pixels live outside the display. Snapshots still target the view itself.
        let container = NSView(frame:NSRect(x:0,y:0,width:1104,height:724))
        view.frame = NSRect(x:2,y:2,width:1100,height:720)
        view.autoresizingMask = [.width,.height]
        container.addSubview(view)
        window.contentView = container
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.collectionBehavior = [.transient,.ignoresCycle,.fullScreenNone]
        (window as? BrowserWindow)?.isolate()
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        view.navigationDelegate = self
        view.uiDelegate = self
    }
    func resizeViewport(_ size: NSSize) {
        window.setContentSize(NSSize(width:size.width+4,height:size.height+4))
        view.frame = NSRect(origin:NSPoint(x:2,y:2),size:size)
        (window as? BrowserWindow)?.park()
    }
    func setStreamCaptureActive(_ active: Bool) {
        (window as? BrowserWindow)?.streamCaptureActive = active
        NotificationCenter.default.post(name:NSWindow.didChangeOcclusionStateNotification,object:window)
    }
    var pagePixelsOnDisplay: Bool {
        let pageRect = window.convertToScreen(view.convert(view.bounds,to:nil))
        return NSScreen.screens.contains { $0.frame.intersects(pageRect) }
    }
    func status() -> [String: Any] {
        ["progress":Int(view.estimatedProgress*20)*5, "mediaPlaying":hasPlayingVideo, "title": view.title ?? "warpweb", "url": requestedURL ?? view.url?.absoluteString ?? "", "back": view.canGoBack, "forward": view.canGoForward, "loading": view.isLoading, "error": errorMessage, "width": Int(view.bounds.width), "height": Int(view.bounds.height)]
    }
    func stopNavigation() {
        view.stopLoading(); requestedURL = nil
        errorMessage = "Loading stopped"
    }
    func navigate(_ input: String) throws {
        guard let url = browserURL(input) else { throw ProtocolError.malformed }
        cancelScrolling(); clicks.reset()
        errorMessage = ""; requestedURL = url.absoluteString
        view.load(URLRequest(url: url))
    }
    func snapshot(pixelWidth: Int? = nil) async throws -> CGImage {
        guard !snapshotBusy else { throw CLIError("Frame in progress") }
        snapshotBusy = true
        defer { snapshotBusy = false }
        do {
            let config = WKSnapshotConfiguration()
            // WebKit accepts points and multiplies by the helper window's scale.
            // Request exact output pixels instead of accidentally supersampling twice.
            config.snapshotWidth = NSNumber(value: Double(pixelWidth ?? Int(view.bounds.width*window.backingScaleFactor))/window.backingScaleFactor)
            config.afterScreenUpdates = true
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                let pending = SnapshotRequest(continuation)
                pending.timeout = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { pending.finish(.failure(CLIError("WebKit snapshot timed out"))) }
                }
                view.takeSnapshot(with: config) { image, error in
                    if let image { pending.finish(.success(image)) }
                    else { pending.finish(.failure(error ?? CLIError("WebKit snapshot failed"))) }
                }
            }
            guard let bitmap = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw CLIError("Cannot read WebKit frame") }
            if errorMessage.hasPrefix("Snapshot:") { errorMessage = "" }
            return bitmap
        } catch {
            errorMessage = "Snapshot: \(error)"
            throw error
        }
    }
    func frame(png: Bool = false, pixelWidth: Int? = nil) async -> Response {
        do {
            let image = try await snapshot(pixelWidth:pixelWidth)
            return await Task.detached(priority:.userInitiated) {
                FrameRenderer.encode(image, png:png)
            }.value
        } catch { return .json(["error":errorMessage],status:503) }
    }
    func command(_ data: Data) -> Response {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let action = object["action"] as? String else { throw ProtocolError.malformed }
            switch action {
            case "navigate": try navigate(object["url"] as? String ?? "")
            case "back": view.goBack()
            case "forward": view.goForward()
            case "reload": view.reload()
            case "resize":
                let width = min(1920, max(320, object["width"] as? Int ?? 1100))
                let height = min(1200, max(240, object["height"] as? Int ?? 720))
                resizeViewport(NSSize(width: width, height: height))
            case "click", "pointer":
                guard let x = object["x"] as? Double, let y = object["y"] as? Double,
                      x.isFinite, y.isFinite, x >= 0, y >= 0, x <= view.bounds.width, y <= view.bounds.height else { throw ProtocolError.malformed }
                if action == "click" {
                    pointer("down", x: x, y: y)
                    pointer("up", x: x, y: y)
                } else {
                    guard let phase = object["phase"] as? String, ["down", "up", "move", "drag"].contains(phase) else { throw ProtocolError.malformed }
                    pointer(phase, x: x, y: y, shift: object["shift"] as? Bool ?? false)
                }
            case "text":
                guard let text = object["text"] as? String, text.utf8.count <= 16_384 else { throw ProtocolError.malformed }
                for character in text { key(String(character)) }
            case "key":
                guard let value = object["key"] as? String, value.count <= 32 else { throw ProtocolError.malformed }
                key(value, shift: object["shift"] as? Bool ?? false, meta: object["meta"] as? Bool ?? false,
                    ctrl: object["ctrl"] as? Bool ?? false, alt: object["alt"] as? Bool ?? false)
            case "scroll":
                let dy = min(1500, max(-1500, object["dy"] as? Double ?? 0))
                let x = object["x"] as? Double ?? view.bounds.midX
                let y = object["y"] as? Double ?? view.bounds.midY
                guard x.isFinite, y.isFinite, dy.isFinite else { throw ProtocolError.malformed }
                scroll(dy, x: x, y: y)
            default: throw ProtocolError.malformed
            }
            return .json(["ok": true])
        } catch { return .json(["error": "Invalid browser command"], status: 400) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        playingMediaFrames.removeAll()
        cursorKind = "default"; focusArea = "Page"; hoverURL = ""
        errorMessage = ""
        cancelScrolling(); clicks.reset()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        requestedURL = nil
    }
    func webViewDidClose(_ webView: WKWebView) { closeHandler?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        return ["http", "https", "about"].contains(scheme) ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let popupHandler { return popupHandler(configuration) }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

@MainActor private final class SnapshotRequest {
    var continuation: CheckedContinuation<NSImage, Error>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<NSImage, Error>) { self.continuation = continuation }
    func finish(_ result: Result<NSImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

// WebKit receives focus on behalf of the terminal without activating an OS window.
@MainActor private final class BrowserWindow: NSWindow {
    var streamCaptureActive = false
    func isolate() {
        NotificationCenter.default.addObserver(self,selector:#selector(park),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(park),name:NSWindow.didResizeNotification,object:self)
        park()
    }
    @objc func park() {
        guard let screen = NSScreen.screens.max(by:{ $0.frame.maxX < $1.frame.maxX }) else {
            alphaValue = 0
            return
        }
        // Only 1×1 point of the transparent 2-point border overlaps a display.
        setFrameOrigin(NSPoint(x:screen.frame.maxX-1,y:screen.frame.minY-frame.height+1))
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // The selected page is visible in the terminal even while its source window
    // has only its transparent border on a display. Keep WebKit's compositor and timers active.
    override var occlusionState: NSWindow.OcclusionState {
        streamCaptureActive ? [.visible] : super.occlusionState
    }
    override var isKeyWindow: Bool { true }
}
