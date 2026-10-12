import Foundation

public enum NavigationDownloadPolicy {
    public static func shouldDownload(_ response: URLResponse, canShowMIMEType: Bool) -> Bool {
        // Process handoffs can surface a response before usable HTTP metadata
        // exists. A capability hint alone is not evidence of a downloadable file.
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.statusCode != 204, http.statusCode != 205 else { return false }
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if disposition == "attachment" { return true }
        guard let type = response.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !type.isEmpty else { return false }
        // Keep normal documents in WebKit. This does not rewrite the MIME type,
        // sniff bytes, replay requests, or bypass any WebKit response checks.
        if ["text/html", "application/xhtml+xml"].contains(type) { return false }
        return !canShowMIMEType
    }
}
