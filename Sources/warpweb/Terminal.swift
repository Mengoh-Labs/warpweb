import CWarpWeb
import AppKit
import Darwin
import WarpWebCore

@MainActor final class TerminalBrowser {
    var browser: Browser { shell.page }
    let shell: TerminalChrome
    private let diagnostics: SessionDiagnostics?
    var diagnosticsFile: String? { diagnostics?.path }
    let renderScale: Double
    private let output = TerminalOutput()
    private var frameMilliseconds = 0.0
    private var imageEncoder = ""
    private var preparationMilliseconds = 0.0, frameAgeMilliseconds = 0.0
    private var deliveredCaptureMilliseconds = 0.0, deliveredEncodeMilliseconds = 0.0
    // At most one frame being prepared while the preceding image is transferred.
    // Never build a FIFO of stale browser frames behind a slow terminal.
    private struct PreparedFrame {
        let response: Response
        let generation: Int
        let scrollRevision: UInt64
        let raw: Bool
        let started: Double
        let finished: Double
        let captureMilliseconds: Double
        let encodeMilliseconds: Double
    }
    private var renderAhead: Task<PreparedFrame, Never>?
    private var pacingSleep: Task<Void, Never>?
    private var scrollRevision: UInt64 = 0
    private var lastScrollInput = -Double.infinity
    private var lastScrollDirection = 0
    private var staleScrollFrames = 0
    private var inputWakeups = 0
    private var lastInteraction = 0.0
    private var lastPointerMotion = 0.0
    private var activity: NSObjectProtocol?
    private var original = termios()
    private var inputSource: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private var loop: Task<Void, Never>?
    private var escapeTimer: Task<Void, Never>?
    private var parser = TerminalInput()
    private var columns = 80, rows = 24
    private var pixelWidth = 800, pixelHeight = 480
    private var explicitPixels: (Int, Int)?
    private let graphicsIDs: SessionGraphicsIDs
    private var imageID: Int
    private var graphicsReady = false
    private var sharedMemory = false
    private var transportFallback = ""
    private var imageReply: String?
    private var lastGraphicsReply = ""
    private var presentationIntervals: [Double] = []
    private var lastPresentation: Double?
    private var pendingSharedFrame: SharedFrame?
    private var pendingImageID: Int?
    private var imageAcknowledged: Bool?
    private var frameTransferMilliseconds = 0.0
    private var active = false
    private var status = "Checking terminal graphics…"
    private var exitCode: Int32 = 0
    private var generation = 0
    private var mouseReports: [[String: Any]] = []
    private var lastMouseReport: [String: Any] = [:]
    private var pointerDown = false
    private var rightDown = false

    init(browser: Browser, diagnosticsFile: String? = nil, renderScale: Double = 1, streamCapture: Bool = false, graphicsIDs: SessionGraphicsIDs, pointerEnabled: Bool = false) throws {
        self.shell = try TerminalChrome(page: browser, streamCapture:streamCapture)
        self.diagnostics = try diagnosticsFile.map { try SessionDiagnostics(path:$0) }
        self.renderScale = renderScale
        self.graphicsIDs = graphicsIDs; self.imageID = graphicsIDs.first
        self.shell.pointerEnabled = pointerEnabled
    }
    func start() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw CLIError("Run warpweb in an interactive terminal panel, or use --serve for the HTML bridge.")
        }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { throw CLIError("Cannot read terminal settings") }
        guard warpweb_watchdog_activate() == 0 else { throw CLIError("Session cleanup watchdog disconnected") }
        var raw = original; cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw CLIError("Cannot enable terminal input") }
        // The interactive browser renders while the terminal owns macOS focus.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Render the active terminal browser and process its input")
        active = true
        write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[2J")
        resize()
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [weak self] in self?.readInput() }
        input.resume(); inputSource = input
        for number in [SIGINT, SIGTERM, SIGHUP, SIGWINCH] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                if number == SIGWINCH { self?.explicitPixels = nil; self?.resize() }
                else { self?.stop() }
            }
            source.resume(); signals.append(source)
        }
        write(KittyGraphics.probe(id:graphicsIDs.probe))
        loop = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(3)
            while !self.graphicsReady && Date() < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled else { return }
            guard self.graphicsReady else { self.stop(error: "The terminal did not acknowledge Kitty graphics. Use a current Warp build with image support."); return }
            if let probe = try? SharedFrame(Data([255,255,255,255])) {
                self.pendingSharedFrame = probe
                self.pendingImageID = self.graphicsIDs.sharedProbe; self.imageAcknowledged = nil; self.imageReply = nil
                self.write(probe.packet(id:self.graphicsIDs.sharedProbe,width:1,height:1,columns:1,rows:1,query:true))
                self.sharedMemory = await self.awaitImage(timeout:2)
                if !self.sharedMemory { self.transportFallback = "Shared-memory probe: " + (self.imageReply ?? "acknowledgment timed out") }
                probe.unlink(); self.pendingSharedFrame = nil
            }
            while !Task.isCancelled && self.active {
                if self.shell.quitRequested { self.stop(); break }
                let started = ProcessInfo.processInfo.systemUptime
                var prepared: PreparedFrame
                if let ahead = self.renderAhead {
                    prepared = await ahead.value
                    self.renderAhead = nil
                    // A resize, fallback, or long terminal stall invalidates lookahead.
                    if prepared.generation != self.generation || prepared.raw != self.sharedMemory ||
                        prepared.scrollRevision != self.scrollRevision ||
                        ProcessInfo.processInfo.systemUptime-prepared.finished > 0.15 {
                        guard self.active, !Task.isCancelled else { break }
                        if prepared.scrollRevision != self.scrollRevision { self.staleScrollFrames += 1 }
                        prepared = await self.prepareFrame()
                    }
                } else { prepared = await self.prepareFrame() }
                guard self.active, !Task.isCancelled else { break }
                let response = prepared.response, revision = prepared.generation
                if revision == self.generation {
                    self.imageEncoder = prepared.response.imageEncoder ?? ""
                    self.deliveredCaptureMilliseconds = prepared.captureMilliseconds
                    self.deliveredEncodeMilliseconds = prepared.encodeMilliseconds
                    self.preparationMilliseconds = (prepared.finished-prepared.started)*1000
                    if response.status == 200, !self.sharedMemory, self.shell.streamingCapture,
                        self.isVisuallyActive {
                        // Aim to finish near the next ACK instead of leaving an old
                        // prepared frame waiting through a slow transfer. The wait is
                        // bounded; an underestimated transfer never creates a queue.
                        let leadDelay = min(0.1,max(0,(self.frameTransferMilliseconds-self.preparationMilliseconds)/1000))
                        self.renderAhead = Task {
                            if leadDelay > 0 { try? await Task.sleep(for:.seconds(leadDelay)) }
                            return await self.prepareFrame()
                        }
                    }
                    if response.status == 200 {
                        let previous = self.imageID
                        let next = previous == self.graphicsIDs.first ? self.graphicsIDs.second : self.graphicsIDs.first
                        let columns = self.columns, rows = self.rows
                        let transferStart = ProcessInfo.processInfo.systemUptime
                        if self.sharedMemory {
                            let width = self.renderWidth, height = self.renderHeight
                            let frame = await Task.detached(priority:.userInitiated) { try? SharedFrame(response.data) }.value
                            if let frame, revision == self.generation {
                                self.pendingSharedFrame = frame
                                self.pendingImageID = next; self.imageAcknowledged = nil; self.imageReply = nil
                                await self.output.send(frame.packet(id:next,width:width,height:height,columns:columns,rows:rows))
                                let accepted = await self.awaitImage(timeout:1)
                                frame.unlink(); self.pendingSharedFrame = nil
                                if accepted {
                                    self.imageID = next; self.recordPresentation()
                                    self.frameAgeMilliseconds = (ProcessInfo.processInfo.systemUptime-prepared.started)*1000
                                    self.write(KittyGraphics.delete(previous))
                                } else { self.sharedMemory = false; self.transportFallback = "Shared frame: " + (self.imageReply ?? "acknowledgment timed out") }
                            } else if frame == nil { self.sharedMemory = false; self.transportFallback = "Shared frame allocation failed" }
                        } else {
                            let packet = await Task.detached(priority:.userInitiated) {
                                KittyGraphics.frame(response.data,id:next,columns:columns,rows:rows,acknowledge:true)
                            }.value
                            if revision == self.generation, self.active {
                                self.pendingImageID = next; self.imageAcknowledged = nil; self.imageReply = nil
                                await self.output.send(packet)
                                // Keep the previous image until the terminal accepts the
                                // replacement. Deleting it inside the PNG upload races decoding.
                                if await self.awaitImage(timeout:2) {
                                    self.imageID = next; self.recordPresentation()
                                    self.frameAgeMilliseconds = (ProcessInfo.processInfo.systemUptime-prepared.started)*1000
                                    self.write(KittyGraphics.delete(previous))
                                }
                            }
                        }
                        self.frameTransferMilliseconds = (ProcessInfo.processInfo.systemUptime-transferStart)*1000
                        self.status = self.browser.errorMessage.isEmpty ? (self.browser.view.title ?? "Loading…") : self.browser.errorMessage
                    } else {
                        // Retain the last valid image during transient capture/layout failures.
                        self.status = self.browser.errorMessage.isEmpty ? "Waiting for WebKit frame…" : self.browser.errorMessage
                    }
                    self.frameMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
                    self.saveDiagnostics()
                }
                let busy = self.isVisuallyActive
                let interval = busy ? (self.shell.streamingCapture ? 1.0/60 : 1.0/30) : 1.0/10
                let remaining = interval-(ProcessInfo.processInfo.systemUptime-started)
                if remaining > 0 {
                    // Cancel only pacing, never an in-flight capture or upload.
                    let sleep = Task<Void, Never> { try? await Task.sleep(for:.seconds(remaining)) }
                    self.pacingSleep = sleep
                    await sleep.value
                    self.pacingSleep = nil
                }
            }
        }
    }
    private var isVisuallyActive: Bool {
        ProcessInfo.processInfo.systemUptime-lastInteraction < 2 || ProcessInfo.processInfo.systemUptime-lastPointerMotion < 0.2 || browser.view.isLoading || browser.hasPlayingVideo || shell.hasRecentSourceUpdate
    }
    private func prepareFrame() async -> PreparedFrame {
        let revision = generation, raw = sharedMemory
        let inputRevision = scrollRevision
        // Advance the same scroll clock used by the input timer before capture.
        shell.page.advanceScrolling(); shell.chrome.advanceScrolling()
        let started = ProcessInfo.processInfo.systemUptime
        let response: Response
        if active, !Task.isCancelled {
            response = await shell.frame(pixelWidth:renderWidth,pixelHeight:renderHeight,raw:raw)
        } else { response = .json(["error":"Rendering stopped"],status:503) }
        return PreparedFrame(response:response,generation:revision,scrollRevision:inputRevision,raw:raw,started:started,
            finished:ProcessInfo.processInfo.systemUptime,captureMilliseconds:shell.captureMilliseconds,
            encodeMilliseconds:shell.encodeMilliseconds)
    }
    private func recordPresentation() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastPresentation {
            presentationIntervals.append((now-lastPresentation)*1000)
            if presentationIntervals.count > 120 { presentationIntervals.removeFirst() }
        }
        lastPresentation = now
    }
    private func awaitImage(timeout: Double) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime+timeout
        while imageAcknowledged == nil, active, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for:.milliseconds(2))
        }
        pendingImageID = nil
        return imageAcknowledged == true
    }
    func stop(error: String? = nil) {
        guard active else { return }
        pendingSharedFrame?.unlink(); pendingSharedFrame = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        active = false; pacingSleep?.cancel(); renderAhead?.cancel(); renderAhead = nil; loop?.cancel(); escapeTimer?.cancel(); inputSource?.cancel()
        for source in signals { source.cancel() }
        write(KittyGraphics.delete(graphicsIDs.first)+KittyGraphics.delete(graphicsIDs.second)+"\u{1b}[?2004l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?25h\u{1b}[0m\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        warpweb_watchdog_finished()
        if let error { fputs("warpweb: \(error)\n", stderr); exitCode = 1 }
        let code = exitCode
        Task { await shell.stopCapture(); exit(code) }
        Task { try? await Task.sleep(for:.seconds(2)); exit(code) }
    }
    private func write(_ value: String) { write(Data(value.utf8)) }
    private func write(_ data: Data) { output.write(data) }
    private var effectiveScale: Double { min(renderScale,7680.0/Double(pixelWidth),4320.0/Double(pixelHeight)) }
    private var renderWidth: Int { max(1,Int((Double(pixelWidth)*effectiveScale).rounded())) }
    private var renderHeight: Int { max(1,Int((Double(pixelHeight)*effectiveScale).rounded())) }
    private func resize() {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        columns = max(20, Int(size.ws_col)); rows = max(6, Int(size.ws_row))
        let width = explicitPixels?.0 ?? (size.ws_xpixel > 0 ? Int(size.ws_xpixel) : columns*10)
        let height = explicitPixels?.1 ?? (size.ws_ypixel > 0 ? Int(size.ws_ypixel) : rows*20)
        pixelWidth = min(7680, max(320, width))
        pixelHeight = min(4320, max(240, height))
        let scale = browser.window.backingScaleFactor
        shell.resize(width: Double(pixelWidth)/scale, height: Double(pixelHeight)/scale)
        generation += 1
        write(KittyGraphics.delete(graphicsIDs.first)+KittyGraphics.delete(graphicsIDs.second))
        if explicitPixels == nil { write("\u{1b}[14t") }
        saveDiagnostics()
    }
    private func saveDiagnostics() {
        guard let diagnosticsFile else { return }
        var state = shell.state()
        state["processPID"] = getpid(); state["watchdogPID"] = warpweb_watchdog_pid()
        state["diagnosticsFile"] = diagnosticsFile
        state["graphicsIDs"] = [graphicsIDs.probe,graphicsIDs.sharedProbe,graphicsIDs.first,graphicsIDs.second]
        state["terminalColumns"] = columns; state["terminalRows"] = rows
        state["mouseReports"] = mouseReports; state["lastMouseReport"] = lastMouseReport
        state["renderWidth"] = renderWidth; state["renderHeight"] = renderHeight
        state["transportFallback"] = transportFallback
        state["lastGraphicsReply"] = lastGraphicsReply
        if !presentationIntervals.isEmpty {
            let sorted = presentationIntervals.sorted()
            state["deliveryIntervalMedianMilliseconds"] = sorted[sorted.count/2]
            state["deliveryIntervalP95Milliseconds"] = sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]
            state["deliveryIntervalMaxMilliseconds"] = sorted.last!
            state["deliveryFPS"] = Double(sorted.count)*1000/sorted.reduce(0,+)
        }
        state["transport"] = sharedMemory ? "shared-memory" : "png"
        state["transferMilliseconds"] = frameTransferMilliseconds
        state["captureMilliseconds"] = deliveredCaptureMilliseconds
        state["encodeMilliseconds"] = deliveredEncodeMilliseconds
        state["preparationMilliseconds"] = preparationMilliseconds
        state["frameAgeMilliseconds"] = frameAgeMilliseconds
        state["renderPipeline"] = "input-responsive-lookahead"
        state["inputWakeups"] = inputWakeups
        state["staleScrollFramesDiscarded"] = staleScrollFrames
        state["imageEncoder"] = imageEncoder
        state["renderScale"] = effectiveScale; state["frameMilliseconds"] = frameMilliseconds
        state["pixelWidth"] = pixelWidth; state["pixelHeight"] = pixelHeight
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? PrivateFile.write(data, to: URL(fileURLWithPath: diagnosticsFile))
    }
    private func readInput() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        guard count > 0 else { if count == 0 || (errno != EINTR && errno != EAGAIN) { stop() }; return }
        escapeTimer?.cancel()
        for event in parser.feed(Data(bytes.prefix(count))) { handle(event) }
        escapeTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            for event in self.parser.flushEscape() { self.handle(event) }
        }
    }
    private func handle(_ event: TerminalEvent) {
        switch event {
        case .graphics, .pixels: break
        case .mouse(let button, _, _, _) where button == 35:
            lastPointerMotion = ProcessInfo.processInfo.systemUptime
            pacingSleep?.cancel()
        default:
            lastInteraction = ProcessInfo.processInfo.systemUptime
            if let pacingSleep { inputWakeups += 1; pacingSleep.cancel() }
        }
        switch event {
        case .graphics(let response):
            lastGraphicsReply = String(response.prefix(256))
            if response == "i=\(graphicsIDs.probe);OK" { graphicsReady = true; status = "Loading…" }
            if let pendingImageID, response.hasPrefix("i=\(pendingImageID);") {
                imageReply = response
                imageAcknowledged = response == "i=\(pendingImageID);OK"
            }
        case .pixels(let width, let height): explicitPixels = (width,height); resize()
        case .control(3), .control(17): stop()
        case .control(12): shell.focusAddress()
        case .control(20): shell.newTab()
        case .control(23): shell.closeTab()
        case .control(22): (shell.focusedOnChrome ? shell.chrome : browser).edit("paste")
        case .control(24): (shell.focusedOnChrome ? shell.chrome : browser).edit("cut")
        case .control(2): shell.perform("back")
        case .control(6): shell.perform("find")
        case .control(7): shell.perform("findNext")
        case .control(18): shell.perform("reload")
        case .control(13), .control(10): shell.key("Enter")
        case .control(127), .control(8): shell.key("Backspace")
        case .control(9): shell.key("Tab")
        case .control(1): shell.key("a", meta: true)
        case .paste(let text): shell.paste(text)
        case .modifiedKey(let key, let shift, let alt, let ctrl):
            if !shell.shortcut(key,shift:shift,alt:alt,ctrl:ctrl) { shell.key(key,shift:shift,alt:alt,ctrl:ctrl) }
        case .text(let text): shell.text(text)
        case .key("BackTab"): shell.key("Tab", shift: true)
        case .key(let key): if !shell.shortcut(key) { shell.key(key) }
        case .mouse(let button, let column, let row, let released):
            lastMouseReport = ["button":button, "column":column, "row":row, "released":released,
                "inBounds":row >= 1 && row <= rows && column >= 1 && column <= columns]
            if button & 32 == 0 {
                mouseReports.append(lastMouseReport)
                if mouseReports.count > 32 { mouseReports.removeFirst() }
            }
            let x = max(0,min(shell.chrome.view.bounds.width-1,(Double(column)-0.5)*shell.chrome.view.bounds.width/Double(columns)))
            let y = max(0,min(shell.chrome.view.bounds.height-1,(Double(row)-0.5)*shell.chrome.view.bounds.height/Double(rows)))
            if released && pointerDown { pointerDown = false; shell.pointer("up", x:x, y:y, right:rightDown); rightDown = false; return }
            guard row >= 1, row <= rows, column >= 1, column <= columns else { return }
            if button & 64 != 0 {
                if !released {
                    let now = ProcessInfo.processInfo.systemUptime
                    let direction = button & 1 == 0 ? -1 : 1
                    // Do not invalidate every frame during a steady gesture:
                    // encoding would repeatedly lose the benefit of lookahead.
                    if now-lastScrollInput > 0.12 || direction != lastScrollDirection {
                        scrollRevision &+= 1
                    }
                    lastScrollInput = now; lastScrollDirection = direction
                    shell.scroll(Double(direction*40), x:x, y:y)
                }
            } else if button & 3 == 0 || button & 3 == 2 || button & 32 != 0 {
                let phase = released ? "up" : (button & 32 != 0 ? (button & 3 == 0 ? "drag" : "move") : "down")
                if phase == "down" { pointerDown = true; rightDown = button & 3 == 2 }
                shell.pointer(phase, x:x, y:y, right:button & 3 == 2)
            }
        default: break
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
