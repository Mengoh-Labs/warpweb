import Foundation
import Testing
@testable import WarpWebCore

private let pageURL = URL(string: "https://example.com/")!
private func response(_ type: String? = nil, disposition: String? = nil, status: Int = 200) -> HTTPURLResponse {
    var headers: [String: String] = [:]
    headers["Content-Type"] = type
    headers["Content-Disposition"] = disposition
    return HTTPURLResponse(url: pageURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

@Test func incompleteNavigationResponseDoesNotBecomeDownload() {
    let provisional = URLResponse(url: pageURL, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    #expect(!NavigationDownloadPolicy.shouldDownload(provisional, canShowMIMEType: false))
    #expect(!NavigationDownloadPolicy.shouldDownload(response(), canShowMIMEType: false))
    #expect(!NavigationDownloadPolicy.shouldDownload(response("text/html", status: 0), canShowMIMEType: false))
}

@Test func htmlNavigationDoesNotBecomeDownloadFromCapabilityHint() {
    for type in ["text/html; charset=utf-8", "application/xhtml+xml"] {
        #expect(!NavigationDownloadPolicy.shouldDownload(response(type), canShowMIMEType: false))
    }
}

@Test func explicitAttachmentsAndUnsupportedFilesStillDownload() {
    #expect(NavigationDownloadPolicy.shouldDownload(response("text/html", disposition: "attachment; filename=page.html"), canShowMIMEType: true))
    #expect(NavigationDownloadPolicy.shouldDownload(response(disposition: " Attachment ; filename=file"), canShowMIMEType: false))
    #expect(NavigationDownloadPolicy.shouldDownload(response("application/octet-stream"), canShowMIMEType: false))
    #expect(!NavigationDownloadPolicy.shouldDownload(response("application/pdf"), canShowMIMEType: true))
    #expect(!NavigationDownloadPolicy.shouldDownload(response("text/html", disposition: "inline"), canShowMIMEType: false))
    #expect(!NavigationDownloadPolicy.shouldDownload(response("text/html", disposition: "attachmentish"), canShowMIMEType: false))
}

@Test func failedResponsesDoNotCreateDownloads() {
    for status in [204, 205, 302, 404, 500] {
        #expect(!NavigationDownloadPolicy.shouldDownload(response("application/octet-stream", disposition: "attachment", status: status), canShowMIMEType: false))
    }
}
