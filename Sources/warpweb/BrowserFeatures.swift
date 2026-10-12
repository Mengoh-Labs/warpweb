import AppKit
import WebKit
import WarpWebCore

struct BrowserDialog {
    let kind: String
    let message: String
    let origin: String
    var value: String = ""
    var multiple: Bool = false
}

extension Browser: WKDownloadDelegate {
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard [NSURLAuthenticationMethodHTTPBasic,NSURLAuthenticationMethodHTTPDigest].contains(challenge.protectionSpace.authenticationMethod) else { return (.performDefaultHandling,nil) }
        let origin = challenge.protectionSpace.host
        guard let user = await dialogHandler?(BrowserDialog(kind:"prompt",message:"Username for this website",origin:origin)),
              let password = await dialogHandler?(BrowserDialog(kind:"password",message:"Password for this website",origin:origin)) else { return (.cancelAuthenticationChallenge,nil) }
        return (.useCredential,URLCredential(user:user,password:password,persistence:.forSession))
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await dialogHandler?(BrowserDialog(kind:"alert", message:message, origin:frame.request.url?.host ?? "Page"))
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await dialogHandler?(BrowserDialog(kind:"confirm", message:message, origin:frame.request.url?.host ?? "Page")) != nil
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await dialogHandler?(BrowserDialog(kind:"prompt", message:prompt, origin:frame.request.url?.host ?? "Page", value:defaultText ?? ""))
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let answer = await dialogHandler?(BrowserDialog(kind:"upload", message:parameters.allowsMultipleSelection ? "Enter file paths, one per line." : "Enter the path of the file to upload.", origin:frame.request.url?.host ?? "Page", multiple:parameters.allowsMultipleSelection)) else { return nil }
        let paths = answer.split(separator:"\n").map { ($0.trimmingCharacters(in:.whitespaces) as NSString).expandingTildeInPath }
        guard !paths.isEmpty, parameters.allowsMultipleSelection || paths.count == 1 else { errorMessage = "Choose a valid file path"; return nil }
        var urls: [URL] = []
        for path in paths {
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath:path, isDirectory:&directory),
                  parameters.allowsDirectories || !directory.boolValue else { errorMessage = "File not found or unsupported: \(path)"; return nil }
            urls.append(URL(fileURLWithPath:path))
        }
        return urls
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        NavigationDownloadPolicy.shouldDownload(navigationResponse.response,
            canShowMIMEType: navigationResponse.canShowMIMEType) ? .download : .allow
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        do {
            let directory = downloadDirectory ?? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0].appendingPathComponent("warpweb", isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let filename = (suggestedFilename as NSString).lastPathComponent
            var destination = directory.appendingPathComponent(filename.isEmpty || filename == "." || filename == ".." ? "download" : filename)
            if FileManager.default.fileExists(atPath:destination.path) {
                destination = directory.appendingPathComponent(UUID().uuidString+"-"+destination.lastPathComponent)
            }
            errorMessage = "Downloading: \(destination.lastPathComponent)"
            return destination
        } catch { errorMessage = "Download failed: \(error.localizedDescription)"; return nil }
    }
    func downloadDidFinish(_ download: WKDownload) { errorMessage = "Download saved" }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { errorMessage = "Download failed: \(error.localizedDescription)" }
}

@MainActor final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var receiver: (any WKScriptMessageHandler)?
    init(_ receiver: any WKScriptMessageHandler) { self.receiver = receiver }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiver?.userContentController(userContentController,didReceive:message)
    }
}
extension Browser: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let data = message.body as? [String:Any] else { return }
        if message.name == "mediaState", let id = data["id"] as? String, let playing = data["playing"] as? Bool {
            if playing { playingMediaFrames[id] = true } else { playingMediaFrames.removeValue(forKey:id) }
            return
        }
        if message.name == "pageFeedback" {
            if let kind = data["cursor"] as? String, ["default","pointer","text"].contains(kind) { cursorKind = kind }
            if let focus = data["focus"] as? String, ["Page","Text field","Control"].contains(focus) { focusArea = focus }
            hoverURL = ""
            if let link = data["link"] as? String, link.utf8.count <= 4096,
               var url = URLComponents(string:link), ["http","https"].contains(url.scheme?.lowercased() ?? "") {
                url.user = nil; url.password = nil; hoverURL = url.string ?? ""
            }
            return
        }
        guard message.name == "pageContext" else { return }
        contextHandler?(data["link"] as? String)
    }
}
