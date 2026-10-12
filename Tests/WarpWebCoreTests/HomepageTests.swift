import Foundation
import Testing
import WarpWebCore

@Test func homepagePersistsAndRejectsUnsupportedSchemes() throws {
    let suite = "warpweb-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let settings = HomepageSettings(defaults:defaults)
    #expect(settings.url == "https://www.google.com/?hl=en&gl=us")
    try settings.set("example.org")
    #expect(HomepageSettings(defaults:UserDefaults(suiteName:suite)!).url == "https://example.org")
    #expect(throws:ProtocolError.self) { try settings.set("file:///etc/passwd") }
    #expect(settings.url == "https://example.org")
}
