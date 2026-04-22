import Foundation
import Network

// MARK: - HTTP Router

/// Handlers receive the raw body and the source IP of the caller. The IP is
/// "127.0.0.1" / "::1" for localhost requests, or a dotted/hex IP for LAN
/// callers (when the server is bound to 0.0.0.0). Routes don't usually need
/// to look at the IP directly — the auth gate in MurmurHTTPServer rejects
/// unapproved remote hosts before routing — but exempt routes (like health)
/// can use it.
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
    /// Binding selection — drives whether we accept LAN requests at all.
    enum BindingMode {
        case localhostOnly
        case allInterfaces
    }

    private var listener: NWListener?
    private let router: MurmurHTTPRouter
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.murmur.httpserver")
    private var currentBinding: BindingMode = .localhostOnly

    /// Paths that bypass the auth gate even for LAN requests. /health is
    /// useful for external uptime checks and leaks nothing.
    private let authExemptPaths: Set<String> = ["/api/v1/health"]

    var isRunning: Bool { listener != nil }
    var activeBinding: BindingMode { currentBinding }

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

    func start(binding: BindingMode) throws {
        stop()

        let params = NWParameters.tcp
        // Allow rebinding immediately after a previous listener on the same
        // port was cancelled. Without SO_REUSEADDR, toggling LAN exposure
        // would intermittently fail with EADDRINUSE because cancel() is
        // async and the port lingers briefly.
        params.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let newListener: NWListener
        switch binding {
        case .localhostOnly:
            // Explicitly bind to 127.0.0.1. `acceptLocalOnly` on NWParameters
            // is cosmetic — observed in practice to still accept LAN traffic
            // when the listener binds to ::.port. Setting requiredLocalEndpoint
            // to the loopback IPv4 address forces a bind on 127.0.0.1 only,
            // which is enforced at the kernel level.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: nwPort
            )
            newListener = try NWListener(using: params)
        case .allInterfaces:
            newListener = try NWListener(using: params, on: nwPort)
        }
        listener = newListener

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let label = binding == .localhostOnly ? "127.0.0.1" : "0.0.0.0"
                NSLog("[HTTP] Server listening on \(label):\(self.port)")
            case .failed(let error):
                NSLog("[HTTP] Server failed: \(error)")
                newListener.cancel()
                if self.listener === newListener { self.listener = nil }
            case .waiting(let error):
                NSLog("[HTTP] Server waiting: \(error)")
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        newListener.start(queue: queue)
        currentBinding = binding
        NSLog("[HTTP] Listener start invoked (binding=\(binding == .localhostOnly ? "localhostOnly" : "allInterfaces"))")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        NSLog("[HTTP] Server stopped")
    }

    /// Restart the listener on the new binding. No-op if the binding matches
    /// and we're already running. Cancels first, waits briefly for the port
    /// to release, then re-binds — NWListener.cancel() is async and racing
    /// a new bind produces EADDRINUSE without that gap.
    func restart(binding: BindingMode) {
        if binding == currentBinding && isRunning { return }
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            do {
                try self.start(binding: binding)
            } catch {
                NSLog("[HTTP] Failed to restart on \(binding == .localhostOnly ? "localhost" : "LAN"): \(error)")
            }
        }
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

            let sourceIp = Self.extractSourceIP(connection: connection)

            // Record every non-localhost, non-approved IP in the pending
            // list — regardless of path. Exempt paths (health) still respond
            // 200, but the user gets visibility that "someone is calling us"
            // so they can approve the host. Without this, health requests
            // would silently succeed and never surface the caller.
            if let ip = sourceIp,
               !ClaudeHostRegistry.isLocalhost(ip: ip),
               !ClaudeHostRegistry.shared.isApproved(ip: ip) {
                ClaudeHostRegistry.shared.recordPending(ip: ip)
            }

            // Auth gate: localhost and exempt paths pass; approved remote IPs
            // pass; anything else returns 403 pending_approval.
            if !self.isAuthorized(sourceIp: sourceIp, path: request.path) {
                let body = self.jsonBytes([
                    "status": "pending_approval",
                    "message": "Open Murmur → Settings → Claude → Approved Hosts to approve this host.",
                    "ip": sourceIp ?? "unknown"
                ])
                self.sendResponse(connection: connection, statusCode: 403, body: body)
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

    private func isAuthorized(sourceIp: String?, path: String) -> Bool {
        if authExemptPaths.contains(path) { return true }
        guard let ip = sourceIp else { return false }
        if ClaudeHostRegistry.isLocalhost(ip: ip) { return true }
        return ClaudeHostRegistry.shared.isApproved(ip: ip)
    }

    private static func extractSourceIP(connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let addr):
            return "\(addr)"
        case .ipv6(let addr):
            // IPv4-mapped IPv6 "::ffff:192.168.1.2" → flatten to the IPv4
            // form so approvals don't double-count the same host by family.
            let s = "\(addr)"
            if s.hasPrefix("::ffff:"), let v4 = s.components(separatedBy: ":").last {
                return v4
            }
            return s
        case .name(let name, _):
            return name
        @unknown default:
            return nil
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
        case 403: statusText = "Forbidden"
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
