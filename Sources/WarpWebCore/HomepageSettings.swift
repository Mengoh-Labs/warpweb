import Foundation

public struct HomepageSettings {
    public static let defaultURL = "https://www.google.com/?hl=en&gl=us"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? (Bundle.main.bundleIdentifier == "ai.quandrylabs.warpweb"
            ? .standard : UserDefaults(suiteName:"ai.quandrylabs.warpweb")!)
    }
    public var url: String {
        defaults.string(forKey:"homepage").flatMap(browserURL)?.absoluteString ?? Self.defaultURL
    }
    public func set(_ input: String) throws {
        guard let url = browserURL(input) else { throw ProtocolError.malformed }
        defaults.set(url.absoluteString,forKey:"homepage")
    }
}
