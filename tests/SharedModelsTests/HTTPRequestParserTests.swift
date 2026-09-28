import XCTest
@testable import SharedModels

final class HTTPRequestParserTests: XCTestCase {

    private func request(_ raw: String) -> Data { Data(raw.utf8) }

    func testParsesSimpleGet() {
        let req = HTTPRequestParser.parse(request("GET /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1:7878\r\n\r\n"))
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/api/v1/health")
        XCTAssertEqual(req?.headers["host"], "127.0.0.1:7878")
        XCTAssertNil(req?.body)
    }

    func testHeaderKeysAreLowercased() {
        let req = HTTPRequestParser.parse(request("POST /x HTTP/1.1\r\nContent-Type: application/json\r\nORIGIN: http://evil.example\r\n\r\n"))
        XCTAssertEqual(req?.headers["content-type"], "application/json")
        XCTAssertEqual(req?.headers["origin"], "http://evil.example")
    }

    func testParsesBodyWithContentLength() {
        let body = #"{"text":"hello"}"#
        let raw = "POST /api/v1/read-aloud HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let req = HTTPRequestParser.parse(request(raw))
        XCTAssertEqual(req?.body, Data(body.utf8))
    }

    func testBodyContainingHeaderTerminatorIsPreserved() {
        // A body that itself contains \r\n\r\n must not be truncated at the
        // first occurrence inside the body.
        let body = "line1\r\n\r\nline2"
        let raw = "POST /x HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let req = HTTPRequestParser.parse(request(raw))
        XCTAssertEqual(req?.body, Data(body.utf8))
    }

    func testTrimsBytesPastContentLength() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcdEXTRA"
        let req = HTTPRequestParser.parse(request(raw))
        XCTAssertEqual(req?.body, Data("abcd".utf8))
    }

    func testNonUTF8BodyIsAccepted() {
        var data = request("POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\n")
        let binaryBody: [UInt8] = [0xFF, 0xFE, 0xFD]
        data.append(contentsOf: binaryBody)
        let req = HTTPRequestParser.parse(data)
        XCTAssertEqual(req?.body, Data(binaryBody))
    }

    func testRejectsGarbage() {
        XCTAssertNil(HTTPRequestParser.parse(request("NONSENSE\r\n\r\n")))
        XCTAssertNil(HTTPRequestParser.parse(Data([0xFF, 0x00, 0x01])))
    }

    func testContentLengthFromPartialHeaders() {
        let headers = Data("POST /x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1234".utf8)
        XCTAssertEqual(HTTPRequestParser.contentLength(inHeaderSection: headers), 1234)
        XCTAssertNil(HTTPRequestParser.contentLength(inHeaderSection: Data("GET / HTTP/1.1".utf8)))
    }

    func testHeaderEndRangeDetectsCompletion() {
        XCTAssertNil(HTTPRequestParser.headerEndRange(in: Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertNotNil(HTTPRequestParser.headerEndRange(in: Data("GET / HTTP/1.1\r\n\r\n".utf8)))
    }

    func testHeaderEndRangeOnDataSlice() {
        // The accumulation loop passes Data slices with non-zero start
        // indices; the parser must not assume zero-based indexing.
        let full = Data("XXXXGET / HTTP/1.1\r\n\r\n".utf8)
        let slice = full[4...]
        XCTAssertNotNil(HTTPRequestParser.headerEndRange(in: Data(slice)))
    }
}

/// The incremental header scan added so a large POST body isn't re-scanned
/// from byte zero on every 64 KB read.
final class HTTPRequestParserIncrementalScanTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    func testOffsetZeroMatchesTheWholeBufferScan() {
        let request = data("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi")
        let expected = HTTPRequestParser.headerEndRange(in: request)
        XCTAssertNotNil(expected)
        XCTAssertEqual(HTTPRequestParser.headerEndRange(in: request, searchingFrom: 0), expected)
    }

    func testFindsTerminatorThatStartsAfterTheOffset() {
        let request = data("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi")
        let found = HTTPRequestParser.headerEndRange(in: request, searchingFrom: 10)
        XCTAssertEqual(found, HTTPRequestParser.headerEndRange(in: request))
    }

    /// The reason callers must overlap by `headerTerminatorLength - 1`: the
    /// blank line can straddle two reads.
    func testTerminatorSplitAcrossReadsIsFoundWithOverlap() {
        let head = data("GET /x HTTP/1.1\r\nHost: a\r\n\r")
        let full = head + data("\nbody")
        // Naive resume at the previous length would start past the "\r".
        let overlap = max(0, head.count - (HTTPRequestParser.headerTerminatorLength - 1))
        XCTAssertNotNil(HTTPRequestParser.headerEndRange(in: full, searchingFrom: overlap))
        XCTAssertEqual(
            HTTPRequestParser.headerEndRange(in: full, searchingFrom: overlap),
            HTTPRequestParser.headerEndRange(in: full)
        )
    }

    func testNoTerminatorYetReturnsNil() {
        let partial = data("GET /x HTTP/1.1\r\nHost: a\r\n")
        XCTAssertNil(HTTPRequestParser.headerEndRange(in: partial, searchingFrom: 4))
    }

    func testOffsetBeyondBufferIsSafe() {
        let partial = data("GET /x HTTP/1.1\r\n")
        XCTAssertNil(HTTPRequestParser.headerEndRange(in: partial, searchingFrom: 9_999))
    }
}
