import AppKit
import CoreImage
import Metal
import ScreenCaptureKit
import WarpWebCore


// Some ScreenCaptureKit connection failures discard completion handlers. Own
// the continuation and deadline so a lost reply cannot freeze browser rendering.
@MainActor private final class CaptureReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil; continuation.resume(with:result)
    }
}
private struct CaptureContent: @unchecked Sendable { let value: SCShareableContent }
@MainActor private func captureReply<Value: Sendable>(_ operation: String,
    start: (CaptureReply<Value>) -> Void) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let reply = CaptureReply(continuation)
        start(reply)
        Task {
            try? await Task.sleep(for:.seconds(3))
            reply.finish(.failure(CLIError("ScreenCaptureKit \(operation) timed out")))
        }
    }
}
@MainActor private func stopCapture(_ stream: SCStream) async {
    let _: Void? = try? await captureReply("stop") { reply in
        stream.stopCapture { error in
            Task { @MainActor in reply.finish(error.map { .failure($0) } ?? .success(())) }
        }
    }
}

/// The callback queue owns incoming surfaces; a lock publishes only the newest one.
/// Holding one pixel buffer keeps its IOSurface alive until conversion completes.
private final class CaptureFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let sequence: Int
        let received: Double
    }
    private let lock = NSLock()
    private var latest: Frame?
    private var count = 0
    private var failure: NSError?
    private var statuses: [Int:Int] = [:]
    func summary() -> String { lock.withLock { String(describing:statuses) } }
    func read() -> (Frame?, NSError?) { lock.withLock { (latest, failure) } }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = error as NSError }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let status = attachments.first?[.status] as? Int else { return }
        lock.withLock { statuses[status,default:0] += 1 }
        guard status == SCFrameStatus.complete.rawValue, let buffer = sampleBuffer.imageBuffer else { return }
        lock.withLock {
            count += 1
            latest = Frame(buffer:buffer,sequence:count,received:ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// Experimental, window-only capture. Never constructs a display capture filter.
@MainActor final class WindowCapture {
    #if DEBUG
    private var injectedTestFailure = false
    #endif
    private var stream: SCStream?
    private var frames: CaptureFrames?
    private weak var window: NSWindow?
    private weak var browser: Browser?
    private var originalLevel = NSWindow.Level.normal
    private var originalAlpha: CGFloat = 0.01
    private var size = NSSize.zero
    private var image: CGImage?
    private var sequence = 0
    private let context: CIContext?
    private(set) var fallbackReason = ""
    private(set) var lastFailure = ""
    private var recovery = CaptureRecovery()
    var recoveryAttempts: Int { recovery.attempts }
    var recoveryPending: Bool { recovery.retryAt != nil }
    private(set) var frameAgeMilliseconds = 0.0
    private(set) var receivedFrames = 0
    private(set) var active = false
    private(set) var conversion = "none"

    var hasRecentSourceUpdate: Bool {
        guard active, let latest = frames?.read().0 else { return false }
        return ProcessInfo.processInfo.systemUptime-latest.received < 0.15
    }

    init() {
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice:$0, options:[.cacheIntermediates:false]) }
    }

    private func detach() -> SCStream? {
        let previous = stream
        stream = nil; frames = nil; image = nil; sequence = 0; active = false
        conversion = "none"
        if let window {
            window.alphaValue = originalAlpha
            window.level = originalLevel
            window.sharingType = .none
        }
        browser?.setStreamCaptureActive(false); browser = nil
        window = nil
        return previous
    }
    func stop() async {
        if let previous = detach() { await stopCapture(previous) }
    }
    func closeIfCapturing(_ browser: Browser) -> Bool {
        guard self.browser === browser else { return false }
        let previous = detach()
        // Retain the source until ScreenCaptureKit has released it. Closing the
        // captured window first can interrupt the process's capture connection.
        Task {
            if let previous { await stopCapture(previous) }
            browser.window.orderOut(nil)
        }
        return true
    }

    func frame(browser: Browser, width: Int) async -> CGImage? {
        if !fallbackReason.isEmpty {
            guard recovery.beginRetry(now:ProcessInfo.processInfo.systemUptime) else { return nil }
            fallbackReason = ""
        }
        let height = max(1,Int((Double(width)*browser.view.bounds.height/browser.view.bounds.width).rounded()))
        let requestedSize = NSSize(width:width,height:height)
        do {
            if window !== browser.window || size != requestedSize {
                await stop()
                // Preflight when opening a stream, not on every delivered frame.
                // Permission revocation on an active stream arrives via its delegate.
                guard CGPreflightScreenCaptureAccess() else {
                    fallbackReason = "Screen Recording permission is required; grant access and restart --capture stream."
                    return nil
                }
                window = browser.window; self.browser = browser; size = requestedSize
                browser.setStreamCaptureActive(true)
                originalLevel = browser.window.level; originalAlpha = browser.window.alphaValue
                // BrowserWindow keeps page pixels off-display with a transparent anchor.
                browser.window.orderFront(nil)
                browser.window.sharingType = .readOnly
                // Materialize the page's first backing surface before subscribing.
                // A new or newly resized WebKit view may not have committed one yet.
                _ = try await browser.snapshot(pixelWidth:width)
                browser.view.displayIfNeeded()
                let result: CaptureContent = try await captureReply("window discovery") { reply in
                    SCShareableContent.getExcludingDesktopWindows(false,onScreenWindowsOnly:false) { content, error in
                        let result: Result<CaptureContent, Error> = content.map { .success(CaptureContent(value:$0)) }
                            ?? .failure(error ?? CLIError("No capture windows returned"))
                        Task { @MainActor in reply.finish(result) }
                    }
                }
                let content = result.value
                guard self.browser === browser, !Task.isCancelled else { return nil }
                guard let target = content.windows.first(where: {
                    $0.windowID == CGWindowID(browser.window.windowNumber) && $0.owningApplication?.processID == getpid()
                }) else { throw CLIError("warpweb's page window is not available for capture.") }
                let configuration = SCStreamConfiguration()
                configuration.width = width; configuration.height = height
                configuration.sourceRect = CGRect(x:2,y:2,width:browser.view.bounds.width,height:browser.view.bounds.height)
                configuration.minimumFrameInterval = CMTime(value:1,timescale:60)
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.showsCursor = false; configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.shouldBeOpaque = true
                configuration.captureResolution = .best
                if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
                let sink = CaptureFrames()
                let capture = SCStream(filter:SCContentFilter(desktopIndependentWindow:target),configuration:configuration,delegate:sink)
                try capture.addStreamOutput(sink,type:.screen,sampleHandlerQueue:DispatchQueue(label:"warpweb.capture",qos:.userInitiated))
                frames = sink; stream = capture
                let _: Void = try await captureReply("start") { reply in
                    capture.startCapture { error in
                        Task { @MainActor in reply.finish(error.map { .failure($0) } ?? .success(())) }
                    }
                }
                guard self.stream === capture, !Task.isCancelled else {
                    await stopCapture(capture); return nil
                }
                browser.window.level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopWindow))-1)
                browser.window.alphaValue = 1
                // Let the opacity/ordering transaction reach the window server.
                try await Task.sleep(for:.milliseconds(100))
                let deadline = ProcessInfo.processInfo.systemUptime+2
                while sink.read().0 == nil, sink.read().1 == nil, ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    try await Task.sleep(for:.milliseconds(5))
                }
            }
            guard self.browser === browser else { return nil }
            guard let frames else { throw CLIError("Capture stream is unavailable.") }
            let (latest, failure) = frames.read()
            if let failure { throw failure }
            guard let latest else { throw CLIError("No complete frames arrived from the page window (statuses: \(frames.summary())).") }
            frameAgeMilliseconds = (ProcessInfo.processInfo.systemUptime-latest.received)*1000
            if browser.hasPlayingVideo && frameAgeMilliseconds > 2000 {
                throw CLIError("Capture stopped updating during media playback.")
            }
            receivedFrames = latest.sequence
            if sequence != latest.sequence {
                let context = self.context
                let converted = await Task.detached(priority:.userInitiated) { () -> (CGImage?, String) in
                    if let image = PixelBufferImage.make(latest.buffer) { return (image, "direct-bgra") }
                    guard let context else { return (nil as CGImage?, "unavailable") }
                    let source = CIImage(cvPixelBuffer:latest.buffer)
                    return (context.createCGImage(source,from:source.extent,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB(),deferred:false), "core-image")
                }.value
                guard self.browser === browser else { return nil }
                guard let capturedImage = converted.0 else { throw CLIError("Cannot convert captured surface.") }
                image = capturedImage; conversion = converted.1; sequence = latest.sequence
            }
            active = true
            recovery.succeeded(now:ProcessInfo.processInfo.systemUptime)
            #if DEBUG
            // Exercise the real delegate-error -> stop -> restart path in an owned
            // PTY. This fault injection is absent from release builds.
            if !injectedTestFailure, ProcessInfo.processInfo.environment["WARPWEB_TEST_CAPTURE_RECOVERY"] == "1", let stream {
                injectedTestFailure = true
                Task { [weak self] in
                    try? await Task.sleep(for:.seconds(2))
                    guard let self, self.stream === stream else { return }
                    frames.stream(stream,didStopWithError:NSError(domain:SCStreamErrorDomain,
                        code:SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue))
                }
            }
            #endif
            return image
        } catch {
            guard self.browser === browser else { return nil }
            fallbackReason = (error as? CLIError)?.description ?? error.localizedDescription
            lastFailure = fallbackReason
            recovery.failed(error as NSError,now:ProcessInfo.processInfo.systemUptime)
            await stop()
            return nil
        }
    }
}
