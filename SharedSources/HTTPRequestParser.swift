import Foundation

/// Parses raw HTTP/1.1 request bytes. Extracted from MurmurHTTPServer so the
/// parsing rules (header/body split, Content-Length trimming, non-UTF-8
/// bodies) are unit-testable.
public enum HTTPRequestParser {
    public struct Request {
        public let method: String
        public let path: String
        /// Header names lowercased.
        public let headers: [String: String]
        public let body: Data?
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Range of the blank line that ends the header section, if it has
    /// fully arrived.
    public static func headerEndRange(in data: Data) -> Range<Data.Index>? {
        data.range(of: headerTerminator)
    }

    /// Content-Length declared in a (possibly partial) header section.
    public static func contentLength(inHeaderSection headerData: Data) -> Int? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "content-length" {
                return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    public static func parse(_ data: Data) -> Request? {
        // Slice the body as raw bytes at the header boundary — round-tripping
        // the whole request through String rejects any non-UTF-8 body.
        let headerData: Data
        var body: Data? = nil
        if let headerEnd = headerEndRange(in: data) {
            headerData = data[..<headerEnd.lowerBound]
            let bodyData = data[headerEnd.upperBound...]
            if !bodyData.isEmpty {
                body = Data(bodyData)
            }
        } else {
            headerData = data
        }

        guard let headerSection = String(data: headerData, encoding: .utf8) else { return nil }

        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        // Parse request line: METHOD /path HTTP/1.1
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = requestParts[0]
        let path = requestParts[1]

        var headers: [String: String] = [:]
        for i in 1..<headerLines.count {
            let line = headerLines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Trim any bytes past the declared Content-Length (e.g. a pipelined
        // follow-up request sharing the connection).
        if let body_ = body,
           let lenString = headers["content-length"],
           let declared = Int(lenString),
           declared >= 0, declared < body_.count {
            body = body_.prefix(declared)
        }

        return Request(method: method, path: path, headers: headers, body: body)
    }
}
