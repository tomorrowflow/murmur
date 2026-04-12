import Foundation
import Network

// MARK: - HTTP Router

typealias HTTPHandler = (_ body: Data?) async -> (statusCode: Int, responseBody: Data)

class MurmurHTTPRouter {
    private var getHandlers: [String: HTTPHandler] = [:]
    private var postHandlers: [String: HTTPHandler] = [:]

    func get(_ path: String, handler: @escaping HTTPHandler) {
        getHandlers[path] = handler
    }

    func post(_ path: String, handler: @escaping HTTPHandler) {
        postHandlers[path] = handler
    }

    func route(method: String, path: String, body: Data?) async -> (statusCode: Int, responseBody: Data) {
        let handlers = method == "GET" ? getHandlers : postHandlers
        if let handler = handlers[path] {
            return await handler(body)
        }
        return (404, jsonError("Not found"))
    }

    private func jsonError(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": message])
    }
}

// MARK: - HTTP Server

class MurmurHTTPServer {
    private var listener: NWListener?
    private let router: MurmurHTTPRouter
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.murmur.httpserver")

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 7878) {
        self.port = port
        self.router = MurmurHTTPRouter()
    }

    // MARK: - Route Registration

    func get(_ path: String, handler: @escaping HTTPHandler) {
        router.get(path, handler: handler)
    }

    func post(_ path: String, handler: @escaping HTTPHandler) {
        router.post(path, handler: handler)
    }

    // MARK: - Lifecycle

    func start() throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true

        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[HTTP] Server listening on 127.0.0.1:\(self.port)")
            case .failed(let error):
                print("[HTTP] Server failed: \(error)")
                self.listener?.cancel()
                self.listener = nil
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("[HTTP] Server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            guard let request = self.parseHTTPRequest(data) else {
                self.sendResponse(connection: connection, statusCode: 400, body: self.jsonBytes(["error": "Bad request"]))
                return
            }

            Task {
                let (statusCode, responseBody) = await self.router.route(
                    method: request.method,
                    path: request.path,
                    body: request.body
                )
                self.sendResponse(connection: connection, statusCode: statusCode, body: responseBody)
            }
        }
    }

    // MARK: - HTTP Parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        // Split headers from body
        let parts = raw.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else { return nil }

        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        // Parse request line: METHOD /path HTTP/1.1
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = requestParts[0]
        let path = requestParts[1]

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<headerLines.count {
            let line = headerLines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body
        var body: Data? = nil
        if parts.count > 1 {
            let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Response

    private func sendResponse(connection: NWConnection, statusCode: Int, body: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 409: statusText = "Conflict"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = response.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    private func jsonBytes(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
}

// MARK: - JSON Helpers

extension MurmurHTTPServer {
    static func jsonResponse(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    static func parseJSON(_ data: Data?) -> [String: Any]? {
        guard let data = data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
