import AppKit
import WebKit
import WarpWebCore

/// Trusted HTML chrome lives in its own WebKit view, separate from remote pages.
/// The two snapshots share one pixel canvas and one coordinate transform.
@MainActor final class TerminalChrome: NSObject, WKScriptMessageHandler {
    nonisolated static let header: Double = 104, footer: Double = 32
    private var tabs: [(id: String, browser: Browser)]
    private var selected = 0
    private var addressRequest = 0
    private var findQuery = ""
    private var findInFlight = false
    var quitRequested = false
    var pointerEnabled = false
    private var pointerLocation: CGPoint?
    private var pointerPressed = false
    var page: Browser { tabs[selected].browser }
    private var pendingDialogs: [(BrowserDialog, CheckedContinuation<String?, Never>)] = []
    private var dialogVisible = false
    private var menuVisible = false
    private var contextLink: URL?
    private weak var contextRequestBrowser: Browser?
    private var contextRequestDeadline = 0.0
    private var cachedChrome: CGImage?
    private var cachedChromeSize = NSSize.zero
    private var chromeRevision = 0, cachedChromeRevision = -1
    private var lastChromeState: Data?
    private(set) var captureMilliseconds = 0.0, encodeMilliseconds = 0.0
    private let windowCapture: WindowCapture?
    let chrome = Browser()
    var focusedOnChrome = false
    var pointerSeen = false
    private var pressedOnChrome: Bool?
    private var pointerPresses = 0, pointerReleases = 0
    private var recentClicks: [[String: Any]] = []
    private(set) var pointerEvents = 0
    private(set) var lastPointer: [String: Any] = [:]

    init(page: Browser, streamCapture: Bool = false) throws {
        windowCapture = streamCapture ? WindowCapture() : nil
        self.tabs = [(UUID().uuidString,page)]
        super.init()
        configure(page)
        let resources = Bundle.module.resourceURL!.appendingPathComponent("Resources")
        let avatar = try Data(contentsOf: resources.appendingPathComponent("kairo.webp"))
        let html = try String(contentsOf: resources.appendingPathComponent("chrome.html"), encoding: .utf8)
            .replacingOccurrences(of: "{{KAIRO}}", with: avatar.base64EncodedString())
        chrome.view.configuration.userContentController.add(WeakMessageHandler(self), name: "chrome")
        chrome.view.loadHTMLString(html, baseURL: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let action = value["action"] as? String else { return }
        switch action {
        case "openLink":
            if let url = contextLink { newTab(); try? page.navigate(url.absoluteString); focusedOnChrome = false }
        case "copyLink":
            if let url = contextLink { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string) }
        case "downloadLink":
            if let url = contextLink {
                let target = page
                Task { let download = await target.view.startDownload(using:URLRequest(url:url)); download.delegate = target }
            }
        case "menu": menuVisible = value["visible"] as? Bool ?? false
        case "find", "findNext", "findPrevious", "help", "togglePointer", "zoomIn", "zoomOut", "zoomReset", "stop", "back", "forward", "reload", "nextTab", "previousTab": perform(action)
        case "address": focusAddress()
        case "closeCurrentTab": closeTab()
        case "quit": quitRequested = true
        case "newTab": newTab()
        case "selectTab":
            if let id = value["id"] as? String, let index = tabs.firstIndex(where: {$0.id == id}) { selected = index; layoutPage(); focusedOnChrome = false }
        case "closeTab":
            if let id = value["id"] as? String, let index = tabs.firstIndex(where: {$0.id == id}) { closeTab(index) }
        case "dialog":
            guard !pendingDialogs.isEmpty else { return }
            let pending = pendingDialogs.removeFirst()
            dialogVisible = false
            pending.1.resume(returning: value["cancel"] as? Bool == true ? nil : value["value"] as? String ?? "")
            chrome.view.evaluateJavaScript("window.hideDialog?.()", completionHandler:nil)
            focusedOnChrome = false
        case "copy", "cut", "paste": page.edit(action); focusedOnChrome = false
        case "home":
            try? page.navigate(HomepageSettings().url); focusedOnChrome = false
        case "setHomepage":
            Task {
                let target = page
                if let value = await target.dialogHandler?(BrowserDialog(kind:"prompt",message:"Homepage web address",origin:"warpweb",value:HomepageSettings().url)) {
                    do { try HomepageSettings().set(value); target.errorMessage = "Homepage saved" }
                    catch { target.errorMessage = "Enter an http(s) homepage address" }
                }
            }
        case "navigate":
            addressRequest = value["request"] as? Int ?? addressRequest
            do { try page.navigate(value["url"] as? String ?? ""); focusedOnChrome = false }
            catch { page.errorMessage = "Enter an http(s) web address" }
        case "pageFocus": focusedOnChrome = false
        default: break
        }
    }
    func perform(_ action: String) {
        switch action {
        case "find":
            Task {
                guard self.pendingDialogs.isEmpty else { return }
                let target = self.page
                if let query = await target.dialogHandler?(BrowserDialog(kind:"prompt",message:"Find text on this page.",origin:"warpweb",value:self.findQuery)), !query.isEmpty {
                    self.findQuery = query
                    await self.find(query,on:target,backwards:false)
                }
            }
        case "findNext", "findPrevious":
            guard !findQuery.isEmpty else { perform("find"); return }
            let target = page, query = findQuery
            Task { await self.find(query,on:target,backwards:action == "findPrevious") }
        case "help":
            Task {
                guard self.pendingDialogs.isEmpty else { return }
                _ = await self.page.dialogHandler?(BrowserDialog(kind:"help",message:"Shortcuts apply when Warp forwards them to warpweb. Every action is also available in the browser menu.",origin:"warpweb"))
            }
        case "togglePointer": pointerEnabled.toggle(); chromeRevision += 1
        case "zoomIn": page.view.pageZoom = min(3,page.view.pageZoom+0.1)
        case "zoomOut": page.view.pageZoom = max(0.3,page.view.pageZoom-0.1)
        case "zoomReset": page.view.pageZoom = 1
        case "stop": page.stopNavigation()
        case "reload": page.errorMessage = ""; page.view.reload(); focusedOnChrome = false
        case "back": page.errorMessage = ""; page.view.goBack(); focusedOnChrome = false
        case "forward": page.errorMessage = ""; page.view.goForward(); focusedOnChrome = false
        case "nextTab", "previousTab":
            guard pendingDialogs.isEmpty else { return }
            selected = (selected + (action == "nextTab" ? 1 : tabs.count-1)) % tabs.count
            layoutPage(); focusedOnChrome = false
        default: break
        }
    }
    private func find(_ query: String,on target: Browser,backwards: Bool) async {
        guard !findInFlight else { return }
        findInFlight = true; defer { findInFlight = false }
        let config = WKFindConfiguration(); config.wraps = true; config.backwards = backwards
        let result = try? await target.view.find(query,configuration:config)
        target.errorMessage = result?.matchFound == true ? "Found: \(query)" : "No match: \(query)"
    }
    func shortcut(_ key: String,shift: Bool = false,alt: Bool = false,ctrl: Bool = false) -> Bool {
        if !pendingDialogs.isEmpty { return false }
        if key == "Escape" {
            if menuVisible { menuVisible = false; chrome.view.evaluateJavaScript("document.getElementById('menu').hidden=true",completionHandler:nil); chromeRevision += 1; return true }
            if !focusedOnChrome && page.view.isLoading { perform("stop"); return true }
            return false
        }
        let action: String?
        switch (key,alt,ctrl) {
        case ("F1",false,false): action = "help"
        case ("F3",false,false): action = shift ? "findPrevious" : "findNext"
        case ("F5",false,false): action = "reload"
        case ("F6",false,false): focusAddress(); return true
        case ("F8",false,false): action = "togglePointer"
        case ("ArrowLeft",true,false): action = "back"
        case ("ArrowRight",true,false): action = "forward"
        case ("PageDown",false,true): action = "nextTab"
        case ("PageUp",false,true): action = "previousTab"
        case ("+",true,false), ("=",true,false): action = "zoomIn"
        case ("-",true,false): action = "zoomOut"
        case ("0",true,false): action = "zoomReset"
        default: action = nil
        }
        guard let action else { return false }
        perform(action); return true
    }
    private func configure(_ browser: Browser) {
        browser.closeHandler = { [weak self, weak browser] in
            guard let self, let browser, let index = self.tabs.firstIndex(where: {$0.browser === browser}) else { return }
            self.closeTab(index)
        }
        browser.contextHandler = { [weak self, weak browser] link in
            guard let self, let browser, browser === self.page,
                  browser === self.contextRequestBrowser,
                  ProcessInfo.processInfo.systemUptime <= self.contextRequestDeadline else { return }
            self.contextRequestBrowser = nil
            self.contextLink = link.flatMap { URL(string:$0) }.flatMap { ["http","https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            self.menuVisible = true
            self.chrome.view.evaluateJavaScript("window.showContext(\(self.contextLink == nil ? "false" : "true"))",completionHandler:nil)
        }
        browser.dialogHandler = { [weak self] dialog in
            guard let self else { return nil }
            return await withCheckedContinuation { self.pendingDialogs.append((dialog,$0)) }
        }
        browser.popupHandler = { [weak self] configuration in
            guard let self else { return nil }
            let child = Browser(configuration:configuration)
            child.downloadDirectory = self.page.downloadDirectory
            self.configure(child)
            self.tabs.append((UUID().uuidString,child)); self.selected = self.tabs.count-1
            self.layoutPage(); self.focusedOnChrome = false
            return child.view
        }
    }
    private func layoutPage() {
        page.resizeViewport(NSSize(width:chrome.view.bounds.width, height:max(1,chrome.view.bounds.height-Self.header-Self.footer)))
    }
    func newTab() {
        let child = Browser(); child.downloadDirectory = page.downloadDirectory
        configure(child); tabs.append((UUID().uuidString,child)); selected = tabs.count-1
        layoutPage()
        try? child.navigate(HomepageSettings().url)
        focusAddress()
    }
    func closeTab(_ index: Int? = nil) {
        let index = index ?? selected
        guard pendingDialogs.isEmpty else { return }
        let old = tabs.remove(at:index).browser
        old.view.stopLoading()
        if windowCapture?.closeIfCapturing(old) != true { old.window.orderOut(nil) }
        if tabs.isEmpty {
            let replacement = Browser(); replacement.downloadDirectory = old.downloadDirectory
            configure(replacement); tabs.append((UUID().uuidString,replacement)); selected = 0
            try? replacement.navigate(HomepageSettings().url)
            focusAddress()
        } else { selected = min(selected-(index<selected ? 1:0),tabs.count-1) }
        layoutPage()
    }
    func resize(width: Double, height: Double) {
        chrome.resizeViewport(NSSize(width: width, height: height))
        page.resizeViewport(NSSize(width: width, height: max(1,height-Self.header-Self.footer)))
    }
    func focusAddress() {
        focusedOnChrome = true
        chrome.window.makeFirstResponder(chrome.view)
        chrome.view.evaluateJavaScript("window.focusAddress?.()", completionHandler: nil)
    }
    func key(_ key: String, shift: Bool = false, meta: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        (focusedOnChrome ? chrome : page).key(key, shift: shift, meta: meta, ctrl:ctrl, alt:alt)
    }
    func paste(_ text: String) { (focusedOnChrome ? chrome : page).pasteText(text) }
    func text(_ text: String) { for character in text { key(String(character)) } }
    func pointer(_ phase: String, x: Double, y: Double, right: Bool = false) {
        pointerSeen = true; pointerEvents += 1
        pointerLocation = CGPoint(x:x,y:y)
        if phase == "down" { pointerPressed = true }
        if phase == "up" { pointerPressed = false }
        if lastPointer["target"] as? String == "chrome" { chromeRevision += 1 }
        let isChrome = !pendingDialogs.isEmpty || menuVisible || y < Self.header || y >= chrome.view.bounds.height-Self.footer
        if phase == "down" { pressedOnChrome = isChrome; focusedOnChrome = isChrome }
        let targetChrome = pressedOnChrome ?? isChrome
        if targetChrome { chromeRevision += 1 }
        lastPointer = ["phase":phase, "x":x, "y":y, "target":targetChrome ? "chrome" : "page"]
        if phase == "down" { pointerPresses += 1 }
        if phase == "up" { pointerReleases += 1 }
        if phase == "down" || phase == "up" {
            recentClicks.append(lastPointer.merging(["time": Date().timeIntervalSince1970, "right": right]) { _, new in new })
            if recentClicks.count > 32 { recentClicks.removeFirst() }
        }
        let target = targetChrome ? chrome : page
        if phase == "down" {
            contextRequestBrowser = right && !targetChrome ? target : nil
            contextRequestDeadline = ProcessInfo.processInfo.systemUptime + 2
        }
        target.pointer(phase, x: x, y: max(0,min(target.view.bounds.height-1,targetChrome ? y : y-Self.header)), right:right)
        if phase == "up" { pressedOnChrome = nil }
    }
    func scroll(_ dy: Double, x: Double, y: Double) {
        pointerSeen = true
        if menuVisible || !pendingDialogs.isEmpty { chrome.smoothScroll(dy,x:x,y:y); return }
        guard y >= Self.header, y < chrome.view.bounds.height-Self.footer else { return }
        page.smoothScroll(dy, x: x, y: y-Self.header)
    }
    func state() -> [String: Any] {
        var state = page.status()
        state["tabs"] = tabs.map { ["id":$0.id,"title":$0.browser.view.title ?? "New tab","selected":$0.id == tabs[selected].id,"loading":$0.browser.view.isLoading] as [String:Any] }
        state["addressRequest"] = addressRequest
        state["homepage"] = HomepageSettings().url
        state["menu"] = menuVisible
        state["pointerEnabled"] = pointerEnabled
        state["pointerVisible"] = pointerEnabled && pointerLocation != nil
        state["cursorKind"] = lastPointer["target"] as? String == "chrome" ? chrome.cursorKind : page.cursorKind
        state["focusArea"] = focusedOnChrome ? "Browser controls" : page.focusArea
        state["hoverURL"] = lastPointer["target"] as? String == "chrome" ? "" : page.hoverURL
        state["zoom"] = Int((page.view.pageZoom*100).rounded())
        state["dialogReady"] = dialogVisible
        state["dialog"] = pendingDialogs.first?.0.kind ?? ""
        state["helperPagePixelsOnDisplay"] = ([chrome] + tabs.map { $0.browser }).contains { $0.pagePixelsOnDisplay }
        state["captureBackend"] = windowCapture?.active == true ? "stream" : "snapshot"
        state["captureFallback"] = windowCapture?.fallbackReason ?? ""
        state["captureLastFailure"] = windowCapture?.lastFailure ?? ""
        state["captureRecoveryAttempts"] = windowCapture?.recoveryAttempts ?? 0
        state["captureRecoveryPending"] = windowCapture?.recoveryPending ?? false
        state["captureFrames"] = windowCapture?.receivedFrames ?? 0
        state["captureConversion"] = windowCapture?.conversion ?? "none"
        state["captureFrameAgeMilliseconds"] = windowCapture?.frameAgeMilliseconds ?? 0
        state["captureMilliseconds"] = captureMilliseconds; state["encodeMilliseconds"] = encodeMilliseconds
        state["chromeReady"] = !chrome.view.isLoading
        state["screenWidth"] = chrome.view.bounds.width
        state["screenHeight"] = chrome.view.bounds.height
        state["header"] = Self.header; state["footer"] = Self.footer
        state["pointerPresses"] = pointerPresses; state["pointerReleases"] = pointerReleases
        state["recentClicks"] = recentClicks
        state["pointerEvents"] = pointerEvents; state["lastPointer"] = lastPointer
        return state
    }
    var hasRecentSourceUpdate: Bool { windowCapture?.hasRecentSourceUpdate == true }
    var streamingCapture: Bool { windowCapture?.active == true }
    func stopCapture() async { await windowCapture?.stop() }
    func frame(pixelWidth: Int, pixelHeight: Int, raw: Bool = false) async -> Response {
        guard !chrome.view.isLoading else { return .json(["error":"Loading browser controls"], status:503) }
        var state = state(); state["pointerSeen"] = pointerSeen
        if let pending = pendingDialogs.first, !dialogVisible {
            let dialog = pending.0
            let payload: [String:Any] = ["kind":dialog.kind,"message":dialog.message,"origin":dialog.origin,"value":dialog.value,"multiple":dialog.multiple]
            if let data = try? JSONSerialization.data(withJSONObject:payload), let json = String(data:data,encoding:.utf8) {
                focusedOnChrome = true; pressedOnChrome = nil
                chrome.window.makeFirstResponder(chrome.view)
                _ = try? await chrome.view.evaluateJavaScript("window.showDialog(\(json))")
                dialogVisible = true
            }
        }
        let displayKeys = ["addressRequest","tabs","url","title","error","back","forward","loading","pointerSeen","pointerEnabled","focusArea","hoverURL","zoom","progress"]
        let displayState = state.filter { displayKeys.contains($0.key) }
        if let data = try? JSONSerialization.data(withJSONObject:displayState,options:[.sortedKeys]), data != lastChromeState,
           let json = String(data:data,encoding:.utf8) {
            _ = try? await chrome.view.evaluateJavaScript("window.updateChrome?.(\(json))")
            lastChromeState = data; chromeRevision += 1
        }
        let selectedPage = page
        let width = chrome.view.bounds.width, height = chrome.view.bounds.height
        let modal = !pendingDialogs.isEmpty
        do {
            let captureStart = ProcessInfo.processInfo.systemUptime
            let size = NSSize(width:pixelWidth,height:pixelHeight)
            if cachedChrome == nil || cachedChromeSize != size || cachedChromeRevision != chromeRevision || focusedOnChrome || menuVisible || modal {
                let revision = chromeRevision
                cachedChrome = try await chrome.snapshot(pixelWidth:pixelWidth)
                cachedChromeSize = size; cachedChromeRevision = revision
            }
            guard let background = cachedChrome else { throw CLIError("Missing browser controls") }
            var content: CGImage?
            if !modal {
                content = await windowCapture?.frame(browser:selectedPage,width:pixelWidth)
                if content == nil { content = try await selectedPage.snapshot(pixelWidth:pixelWidth) }
            }
            captureMilliseconds = (ProcessInfo.processInfo.systemUptime-captureStart)*1000
            var menuRect: CGRect?
            if menuVisible, let rect = try? await chrome.view.evaluateJavaScript("window.menuRect()") as? [String:Double] {
                menuRect = CGRect(x:rect["x"] ?? 0,y:rect["y"] ?? 0,width:rect["width"] ?? 0,height:rect["height"] ?? 0)
            }
            guard selectedPage === page, width == chrome.view.bounds.width, height == chrome.view.bounds.height,
                  modal == !pendingDialogs.isEmpty else { return .json(["error":"Browser layout changed"],status:503) }
            let frameMenu = menuRect
            let pointer = pointerEnabled ? pointerLocation.map { PointerOverlay(point:$0,kind:state["cursorKind"] as? String ?? "default",pressed:pointerPressed) } : nil
            let encodeStart = ProcessInfo.processInfo.systemUptime
            let response = await Task.detached(priority:.userInitiated) {
                FrameRenderer.compose(background:background,content:content,width:pixelWidth,height:pixelHeight,
                    logicalWidth:width,logicalHeight:height,header:Self.header,footer:Self.footer,menu:frameMenu,pointer:pointer,raw:raw)
            }.value
            encodeMilliseconds = (ProcessInfo.processInfo.systemUptime-encodeStart)*1000
            return response
        } catch { return .json(["error":"Waiting for browser frame"],status:503) }
    }
}
