# Native browser capability preparation

The terminal CLI built by the local scripts is ad-hoc signed. `warpweb --native-status` reports
its actual signature entitlement and, only when entitled, Apple's browser passkey
access state. **The default development build does not enable passkeys.** Apple Passwords/Touch ID AutoFill is reported separately as not integrated. No credential enumeration or
JavaScript WebAuthn replacement is used. WebKit remains responsible for origins,
relying-party checks and website credential requests.

`./scripts/package-native.sh` prepares `.build/native/warpweb.app` with a stable
bundle identifier and HTTP/HTTPS declarations. Run its inner executable from a
terminal. It is a development/review artifact; it is not installed or registered
as the default browser. Finder/cold URL-handler launch into a terminal is not
implemented. The script does not attach managed entitlements to an ad-hoc binary.

`Browser.entitlements` is the requested capability template, not an entitlement
grant. Before a production native passkey build can be validated:

1. The organization's Apple Developer **Account Holder** requests the managed
   macOS browser passkey entitlement for `ai.quandrylabs.warpweb`.
2. Obtain the corresponding signing identity and provisioning profile. Complete
   the app's URL-handler launch integration before browser capability review.
3. Package/sign the app using that profile and its matching application/team
   identifiers, then verify the effective signed entitlements and macOS validation.
4. Run `--native-status`, implement the explicit native user-access request and validate
   WebKit create/get, cancellation, denied access and cross-origin behavior.
5. Verify presentation of Apple's authentication UI with the off-display helper.
   This presentation path is **not yet validated**; it may require an explicit
   visible authentication window. No authentication prompt is captured or proxied.

Adding an entitlement key alone is not a substitute for Apple's provisioning.
A signed/provisioned build requires that external capability and separate validation.
Packaging a development bundle does not configure your Apple account or grant browser capabilities.

Netflix's documented login uses a password or emailed/texted code. Apple Passwords
AutoFill is a separate integration from a WebAuthn passkey; the passkey entitlement
must not be represented as enabling Safari Password AutoFill for arbitrary sites.

References (checked 2026-10-12):

- [Apple browser passkey entitlement and application requirements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [Request managed capability](https://developer.apple.com/contact/request/macos-browsers-passkeys/)
- [WebKit and native browser passkeys](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
- [Netflix sign-in](https://help.netflix.com/en/node/311830241325668)
- [Netflix and password managers](https://help.netflix.com/en/node/464122446329956)

Apple's documented third-party Passwords AutoFill route uses its browser extension.
Warpweb currently has no extension host or verified integration with Apple's native
Passwords component. A browser passkey entitlement does not enable password AutoFill.
This work does not claim that obtaining that entitlement would solve Netflix login.
See [Apple Passwords extensions](https://support.apple.com/guide/passwords/get-extensions-mchlf7ac261e/mac).
