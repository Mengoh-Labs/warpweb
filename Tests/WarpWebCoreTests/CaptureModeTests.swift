import Testing
@testable import WarpWebCore

@Test func automaticCaptureRespectsExistingPermission() {
    #expect(CaptureMode.automatic.usesStream(isServing: false, captureAccess: { true }))
    #expect(!CaptureMode.automatic.usesStream(isServing: false, captureAccess: { false }))
}

@Test func explicitCaptureAndServeDoNotProbePermission() {
    var probes = 0
    let access = { probes += 1; return true }
    #expect(!CaptureMode.snapshot.usesStream(isServing: false, captureAccess: access))
    // Explicit stream retains its existing startup permission check and fallback.
    #expect(CaptureMode.stream.usesStream(isServing: false, captureAccess: access))
    for mode in [CaptureMode.automatic, .snapshot, .stream] {
        #expect(!mode.usesStream(isServing: true, captureAccess: access))
    }
    #expect(probes == 0)
}

@Test func captureModeAcceptsOnlySupportedNames() {
    #expect(CaptureMode(rawValue: "auto") == .automatic)
    #expect(CaptureMode(rawValue: "snapshot") == .snapshot)
    #expect(CaptureMode(rawValue: "stream") == .stream)
    #expect(CaptureMode(rawValue: "invalid") == nil)
}
