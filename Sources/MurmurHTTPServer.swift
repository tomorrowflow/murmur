import Foundation
import Network
import SharedModels

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

    /// Upper bound on a single request (headers + body). Recap texts can be
    /// long, but nothing legitimate approaches megabytes.
    private static let maxRequestBytes = 2 * 1024 * 1024

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        // Idle guard: drop connections that haven't completed a request
        // within 30s, so port scanners / stalled clients don't accumulate
        // open connections. Cancelling an already-finished connection is a
        // no-op.
        queue.asyncAfter(deadline: .now() + 30) { [weak connection] in
            connection?.cancel()
        }

        receiveRequest(connection: connection, accumulated: Data())
    }

    /// Read from the connection until the header section AND the
    /// Content-Length-declared body have fully arrived. A single receive()
    /// only returns one batch of TCP segments — POST bodies routinely span
    /// several (long recap texts, curl's separate header/body writes), and
    /// parsing the first segment alone truncated them into opaque 400s.
    private func receiveRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data = data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }
            if buffer.count > Self.maxRequestBytes {
                self.sendResponse(connection: connection, statusCode: 400, body: self.jsonBytes(["error": "Request too large"]))
                return
            }

            // Keep reading until the blank line that ends the headers.
            guard let headerEnd = HTTPRequestParser.headerEndRange(in: buffer) else {
                if isComplete {
                    self.sendResponse(connection: connection, statusCode: 400, body: self.jsonBytes(["error": "Bad request"]))
                } else {
                    self.receiveRequest(connection: connection, accumulated: buffer)
                }
                return
            }

            // Keep reading until the declared body length has arrived.
            let bodyCount = buffer.count - headerEnd.upperBound
            if let expected = HTTPRequestParser.contentLength(inHeaderSection: buffer[..<headerEnd.lowerBound]),
               bodyCount < expected, !isComplete {
                self.receiveRequest(connection: connection, accumulated: buffer)
                return
            }

            self.processRequest(buffer, connection: connection)
        }
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        guard let request = HTTPRequestParser.parse(data) else {
            self.sendResponse(connection: connection, statusCode: 400, body: self.jsonBytes(["error": "Bad request"]))
            return
        }

        // Browsers attach an Origin header to cross-origin fetches and most
        // POSTs; no browser-based client exists, so any Origin-bearing
        // request is a webpage trying to drive the API from inside the
        // localhost trust boundary. Reject it. Same for DNS-rebinding
        // attempts, which arrive with the attacker's hostname in Host.
        if request.headers["origin"] != nil {
            self.sendResponse(connection: connection, statusCode: 403, body: self.jsonBytes(["error": "Browser-originated requests are not allowed"]))
            return
        }
        if let host = request.headers["host"] {
            let hostName = host.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
            let allowedNames: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
            let isOwnAddress = allowedNames.contains(hostName)
                || hostName == Self.localHostname()
                || hostName.allSatisfy { $0.isNumber || $0 == "." }  // raw LAN IP
            if !isOwnAddress {
                self.sendResponse(connection: connection, statusCode: 403, body: self.jsonBytes(["error": "Unexpected Host header"]))
                return
            }
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

    private static func localHostname() -> String {
        ProcessInfo.processInfo.hostName.lowercased()
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

        // Deliberately NO Access-Control-Allow-Origin header: combined with
        // the localhost auto-trust, a wildcard let any webpage drive this API
        // (start recordings, trigger TTS, open draft sessions) via fetch().
        // No browser-based client exists, so CORS stays locked down.
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
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
