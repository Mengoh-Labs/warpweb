import Foundation
import ScreenCaptureKit

/// Retry connection failures, never permission denial or an intentional stop.
public struct CaptureRecovery {
    public private(set) var attempts = 0
    public private(set) var retryAt: Double?
    private var healthySince: Double?
    public init() {}

    public mutating func failed(_ error: NSError, now: Double) {
        healthySince = nil
        retryAt = nil
        let transient: Set<Int> = [
            SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue,
            SCStreamError.Code.failedApplicationConnectionInvalid.rawValue,
            SCStreamError.Code.internalError.rawValue,
            SCStreamError.Code.failedToStart.rawValue
        ]
        guard error.domain == SCStreamErrorDomain, transient.contains(error.code), attempts < 3 else { return }
        retryAt = now + pow(2, Double(attempts+1))
        attempts += 1
    }

    public mutating func beginRetry(now: Double) -> Bool {
        guard let retryAt, now >= retryAt else { return false }
        self.retryAt = nil
        return true
    }

    public mutating func succeeded(now: Double) {
        if healthySince == nil { healthySince = now }
        // A single good frame must not reset a repeatedly failing connection.
        if let healthySince, now-healthySince >= 30 { attempts = 0 }
    }
}
