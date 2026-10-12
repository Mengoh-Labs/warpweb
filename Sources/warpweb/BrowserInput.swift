import AppKit
import WebKit

// Deliver events directly to our own WebKit view. Never post global input or
// activate the helper window: keyboard focus must remain in the terminal.
extension Browser {
    private func location(_ x: Double, _ y: Double) -> NSPoint {
        view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height-y), to: nil)
    }
    func pointer(_ phase: String, x: Double, y: Double, shift: Bool = false, right: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if phase == "down" {
            cancelScrolling()
            pressedClickCount = clicks.press(x:x,y:y,right:right,time:now,interval:NSEvent.doubleClickInterval)
        } else if phase == "drag" { clicks.drag(x:x,y:y) }
        let type: NSEvent.EventType
        switch phase {
        case "down": type = right ? .rightMouseDown : .leftMouseDown; window.makeFirstResponder(view)
        case "up": type = right ? .rightMouseUp : .leftMouseUp
        case "drag": type = .leftMouseDragged
        default: type = .mouseMoved
        }
        guard let event = NSEvent.mouseEvent(with: type, location: location(x,y), modifierFlags: shift ? [.shift] : [],
            timestamp: now, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: phase == "move" ? 0 : pressedClickCount, pressure: phase == "down" || phase == "drag" ? 1 : 0) else { return }
        switch type {
        case .rightMouseDown: view.rightMouseDown(with:event)
        case .rightMouseUp: view.rightMouseUp(with:event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default:
            // AppKit routes movement to tracking-area owners, not WKWebView.
            let selector = #selector(NSResponder.mouseMoved(with:))
            var delivered = Set<ObjectIdentifier>()
            for area in view.trackingAreas where area.options.contains(.mouseMoved) {
                if let owner = area.owner as? NSObject, owner.responds(to: selector), delivered.insert(ObjectIdentifier(owner)).inserted {
                    owner.perform(selector, with: event)
                }
            }
        }
    }
    func pasteText(_ text: String) {
        // NSTextInput's insertion action preserves newlines without turning a
        // pasted newline into Return or a pasted control byte into a shortcut.
        view.perform(NSSelectorFromString("insertText:"),with:text)
    }
    func edit(_ action: String) {
        guard ["copy","cut","paste"].contains(action) else { return }
        NSApp.sendAction(NSSelectorFromString(action+":"), to:view, from:nil)
    }
    func key(_ key: String, shift: Bool = false, meta: Bool = false, ctrl: Bool = false, alt: Bool = false) {
        if meta, let action = ["c":"copy","x":"cut","v":"paste"][key.lowercased()] { edit(action); return }
        if meta && key.lowercased() == "a" { view.selectAll(nil); return }
        let special: [String: (String, UInt16)] = [
            "Enter": ("\r",36), "Tab": ("\t",48), "Backspace": ("\u{7f}",51), "Escape": ("\u{1b}",53),
            "Delete": ("\u{f728}",117), "Home": ("\u{f729}",115), "End": ("\u{f72b}",119),
            "PageUp": ("\u{f72c}",116), "PageDown": ("\u{f72d}",121),
            "ArrowLeft": ("\u{f702}",123), "ArrowRight": ("\u{f703}",124), "ArrowDown": ("\u{f701}",125), "ArrowUp": ("\u{f700}",126)
        ]
        guard special[key] != nil || key.count == 1 else { return }
        let codes: [String: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,
            "]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47," ":49,"`":50]
        let (characters, code) = special[key] ?? (key, codes[key.lowercased()] ?? 0)
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }; if meta { flags.insert(.command) }
        if ctrl { flags.insert(.control) }; if alt { flags.insert(.option) }
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { if !meta || !view.performKeyEquivalent(with: event) { view.keyDown(with: event) } } else { view.keyUp(with: event) }
        }
    }
    func cancelScrolling() {
        scrollTask?.cancel(); scrollTask = nil
        scrollMotion = .init()
    }
    func advanceScrolling() {
        guard scrollMotion.remaining != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now-scrollClock
        guard elapsed > 0 else { return }
        scrollClock = now
        let step = scrollMotion.step(seconds:elapsed)
        if step != 0 { scroll(Double(step), x:scrollPoint.x, y:scrollPoint.y) }
    }
    func smoothScroll(_ dy: Double, x: Double, y: Double) {
        if abs(scrollPoint.x-x) > 40 || abs(scrollPoint.y-y) > 40 { cancelScrolling() }
        let reversing = scrollMotion.remaining != 0 && dy.sign != Double(scrollMotion.remaining).sign
        let starting = scrollMotion.remaining == 0
        scrollPoint = NSPoint(x:x,y:y)
        scrollMotion.add(Int(dy))
        if starting || reversing {
            // A new gesture/reversal responds in this input turn, not next tick.
            scrollClock = ProcessInfo.processInfo.systemUptime-1.0/60
            advanceScrolling()
        }
        guard scrollTask == nil else { return }
        scrollTask = Task { [weak self] in
            let interval = 1.0/60
            var deadline = ProcessInfo.processInfo.systemUptime+interval
            while !Task.isCancelled {
                let delay = max(0,deadline-ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(for:.seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.advanceScrolling()
                if self.scrollMotion.remaining == 0 { self.scrollTask = nil; return }
                // Absolute deadlines avoid adding work duration to every tick.
                let now = ProcessInfo.processInfo.systemUptime
                deadline += interval
                if deadline <= now { deadline += (floor((now-deadline)/interval)+1)*interval }
            }
        }
    }
    func scroll(_ dy: Double, x: Double, y: Double) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0),
              let initial = NSEvent(cgEvent: cg) else { return }
        // CG and AppKit have opposite Y axes. This unposted event has no window,
        // so align its locationInWindow with the view's window coordinates.
        let target = location(x,y), current = initial.locationInWindow
        cg.location = CGPoint(x: cg.location.x + target.x-current.x, y: cg.location.y - (target.y-current.y))
        if let event = NSEvent(cgEvent: cg) { view.scrollWheel(with: event) }
    }
}
