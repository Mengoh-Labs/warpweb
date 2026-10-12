import Foundation

/// SGR mouse reports omit click counts; reconstruct them before creating NSEvents.
public struct PointerClicks {
    private var time = -Double.infinity
    private var x = 0.0, y = 0.0
    private var right = false
    public private(set) var count = 0
    public init() {}
    public mutating func press(x: Double, y: Double, right: Bool, time: Double, interval: Double) -> Int {
        let nearby = abs(self.x-x) <= 4 && abs(self.y-y) <= 4
        count = nearby && right == self.right && time-self.time <= interval ? count+1 : 1
        self.x = x; self.y = y; self.right = right; self.time = time
        return count
    }
    public mutating func drag(x: Double, y: Double) {
        if abs(self.x-x) > 4 || abs(self.y-y) > 4 { time = -.infinity }
    }
    public mutating func reset() { time = -.infinity; count = 0 }
}

/// Bounded, exact pixel totals with an exponential ease-out between wheel reports.
public struct ScrollMotion {
    public private(set) var remaining = 0
    private var continuousRemaining = 0.0
    public init() {}
    public mutating func add(_ pixels: Int) {
        guard pixels != 0 else { return }
        if pixels.signum() != remaining.signum() { remaining = 0; continuousRemaining = 0 }
        remaining = min(800, max(-800, remaining+pixels))
        continuousRemaining = min(800, max(-800,continuousRemaining+Double(pixels)))
    }
    public mutating func step(seconds: Double) -> Int {
        guard remaining != 0, seconds > 0, seconds.isFinite else { return 0 }
        continuousRemaining *= exp(-seconds/0.04)
        let next = Int(continuousRemaining.rounded())
        let step = remaining-next
        remaining = next
        if remaining == 0 { continuousRemaining = 0 }
        return step
    }
}
