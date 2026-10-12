import Foundation
import ScreenCaptureKit
import Testing
@testable import WarpWebCore

@Test func captureConnectionRetriesAreDelayedAndBounded() {
    let error = NSError(domain:SCStreamErrorDomain, code:SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue)
    var recovery = CaptureRecovery()
    recovery.failed(error, now:0)
    let ready0 = recovery.beginRetry(now:1.9)
    #expect(!ready0)
    let ready1 = recovery.beginRetry(now:2)
    #expect(ready1)
    let ready2 = recovery.beginRetry(now:2)
    #expect(!ready2)
    recovery.succeeded(now:2)
    recovery.failed(error, now:3)
    #expect(recovery.retryAt == 7)
    let ready3 = recovery.beginRetry(now:7)
    #expect(ready3)
    recovery.failed(error, now:8)
    #expect(recovery.retryAt == 16)
    let ready4 = recovery.beginRetry(now:16)
    #expect(ready4)
    recovery.failed(error, now:17)
    #expect(recovery.retryAt == nil && recovery.attempts == 3)
    recovery.succeeded(now:20); recovery.succeeded(now:50)
    recovery.failed(error, now:51)
    #expect(recovery.retryAt == 53 && recovery.attempts == 1)
}

@Test func capturePermissionAndUserStopsNeverRetry() {
    for code in [SCStreamError.Code.userDeclined, .userStopped, .missingEntitlements, .invalidParameter] {
        var recovery = CaptureRecovery()
        recovery.failed(NSError(domain:SCStreamErrorDomain,code:code.rawValue), now:0)
        #expect(recovery.retryAt == nil && recovery.attempts == 0)
    }
    var recovery = CaptureRecovery()
    recovery.failed(NSError(domain:"other",code:SCStreamError.Code.internalError.rawValue),now:0)
    #expect(recovery.retryAt == nil)
}
