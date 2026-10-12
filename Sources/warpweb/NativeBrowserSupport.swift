import AppKit
import AuthenticationServices
import Security

/// WebKit owns WebAuthn challenges. Never proxy credential material through JS.
@MainActor enum NativeBrowserSupport {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    static var hasBrowserEntitlement: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue:kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String:Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String:Any] else { return false }
        return entitlements[entitlement] as? Bool == true
    }
    static func status() -> [String:Any] {
        let entitled = hasBrowserEntitlement
        var status: [String:Any] = ["bundleIdentifier":Bundle.main.bundleIdentifier ?? "",
            "browserPasskeyEntitlement":entitled,
            "passkeyAccess":"requires-provisioned-browser",
            "webAuthnHandler":"WebKit",
            "applePasswordsAutoFill":"not-integrated"]
        if entitled {
            status["passkeyAccess"] = label(ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials)
        }
        return status
    }
    private static func label(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> String {
        switch state {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "not-determined"
        @unknown default: "unknown"
        }
    }
}
