import Foundation
import Testing
@testable import WarpWebCore
@Test func fragmentedRequest() throws {
    #expect(try Request.parse(Data("POST /command HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{".utf8)) == nil)
    let request = try #require(try Request.parse(Data("POST /command HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8)))
    #expect(request.method == "POST")
    #expect(request.body == Data("{}".utf8))
    #expect(request.headers["host"] == "localhost")
}
@Test func rejectsAmbiguousFraming() {
    for headers in ["Content-Length: -1", "Content-Length: 2\r\nContent-Length: 3", "Transfer-Encoding: chunked", "Content-Length: nope"] {
        #expect(throws: ProtocolError.self) { try Request.parse(Data("POST / HTTP/1.1\r\n\(headers)\r\n\r\n{}".utf8)) }
    }
}
@Test func limitsRequestSize() {
    #expect(throws: ProtocolError.self) { try Request.parse(Data(repeating: 65, count: 65_537)) }
}
@Test func restrictsNavigationSchemes() {
    #expect(browserURL("example.com")?.absoluteString == "https://example.com")
    #expect(browserURL("http://localhost:8080/test")?.host == "localhost")
    for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "https://", ""] {
        #expect(browserURL(url) == nil)
    }
}
