import Foundation

public struct Request: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public static func parse(_ data: Data) throws -> Request? {
        guard data.count <= 65_536 else { throw ProtocolError.tooLarge }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let text = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw ProtocolError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/") else { throw ProtocolError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ProtocolError.malformed }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw ProtocolError.malformed }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw ProtocolError.malformed }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(rawLength), length <= 60_000 else { throw ProtocolError.malformed }
        let offset = separator.upperBound
        guard data.count >= offset + length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: data.subdata(in: offset..<(offset + length)))
    }
}
public enum ProtocolError: Error { case malformed, tooLarge }

public func browserURL(_ input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    // A hostname may contain a port, so only reject explicit non-web schemes.
    let candidate: String
    if text.contains("://") { candidate = text }
    else if text.hasPrefix("javascript:") || text.hasPrefix("data:") || text.hasPrefix("file:") { return nil }
    else { candidate = "https://" + text }
    guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
}
