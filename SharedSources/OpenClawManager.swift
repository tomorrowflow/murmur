import Foundation
import CryptoKit

// MARK: - Delegate Protocol

public protocol OpenClawManagerDelegate: AnyObject {
    func openClawDidConnect()
    func openClawDidDisconnect(error: Error?)
    func openClawDidReceiveDelta(runId: String, text: String, seq: Int)
    func openClawDidReceiveFinal(runId: String, text: String, seq: Int)
    func openClawDidReceiveError(runId: String, message: String)
    func openClawDidReceiveAborted(runId: String, partialText: String?)
}

// MARK: - Device Identity

private struct DeviceIdentity {
    let privateKey: Curve25519.Signing.PrivateKey
    let publicKey: Curve25519.Signing.PublicKey
    let deviceId: String  // sha256(publicKey raw bytes) as hex

    init() {
        // Try to load persisted keypair, otherwise generate new one
        if let loaded = DeviceIdentity.load() {
            self.privateKey = loaded.privateKey
            self.publicKey = loaded.publicKey
            self.deviceId = loaded.deviceId
        } else {
            let key = Curve25519.Signing.PrivateKey()
            self.privateKey = key
            self.publicKey = key.publicKey
            self.deviceId = DeviceIdentity.deriveDeviceId(from: key.publicKey)
            self.save()
        }
    }

    static func deriveDeviceId(from publicKey: Curve25519.Signing.PublicKey) -> String {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    var publicKeyBase64URL: String {
        base64URLEncode(publicKey.rawRepresentation)
    }

    func sign(_ message: Data) -> String? {
        guard let signature = try? privateKey.signature(for: message) else { return nil }
        return base64URLEncode(signature)
    }

    // MARK: - Persistence

    private static var keyFilePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SuperVoiceAssistant")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("device-key.bin")
    }

    private func save() {
        try? privateKey.rawRepresentation.write(to: DeviceIdentity.keyFilePath)
    }

    private static func load() -> DeviceIdentity? {
        guard let data = try? Data(contentsOf: keyFilePath),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        // Use memberwise init bypass
        var identity = DeviceIdentity(privateKey: key)
        return identity
    }

    // Private init for loading
    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
        self.deviceId = DeviceIdentity.deriveDeviceId(from: privateKey.publicKey)
    }
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - OpenClawManager

public class OpenClawManager: NSObject {
    public weak var delegate: OpenClawManagerDelegate?

    private let url: String
    private let token: String
    private let password: String?
    private let sessionKey: String
    private let deviceIdentity: DeviceIdentity

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var listenTask: Task<Void, Never>?

    public private(set) var isConnected = false
    public private(set) var isAuthenticated = false
    public private(set) var isPendingPairing = false

    /// Callback fired when connection state changes: (isConnected, isAuthenticated, isPendingPairing)
    public var onStatusChange: ((Bool, Bool, Bool) -> Void)?

    public var deviceId: String { deviceIdentity.deviceId }

    private var reconnectAttempt = 0
    private let maxReconnectAttempt = 8
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = true

    private var requestCounter = 0

    public init(url: String, token: String, password: String? = nil, sessionKey: String = "voice-assistant") {
        self.url = url
        self.token = token
        self.password = password
        self.sessionKey = sessionKey
        self.deviceIdentity = DeviceIdentity()
        super.init()
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        NSLog("OpenClaw: device id = \(deviceIdentity.deviceId.prefix(16))...")
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    public func connect() {
        guard !isConnected else { return }
        guard let wsURL = URL(string: url) else {
            NSLog("OpenClaw: invalid URL: \(url)")
            return
        }

        shouldReconnect = true
        isConnected = true  // Set immediately to prevent concurrent connects
        fireStatusChange()
        let task = urlSession.webSocketTask(with: wsURL)
        task.resume()
        webSocketTask = task
        NSLog("OpenClaw: connecting to \(url)")
        startListening()
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        listenTask?.cancel()
        listenTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        isAuthenticated = false
        isPendingPairing = false
        fireStatusChange()
    }

    // MARK: - Chat

    public func sendChat(text: String, sessionKey: String? = nil) -> String {
        let idempotencyKey = UUID().uuidString
        let key = sessionKey ?? self.sessionKey
        let id = nextRequestId()

        let params: [String: Any] = [
            "sessionKey": key,
            "message": text,
            "idempotencyKey": idempotencyKey
        ]

        let frame: [String: Any] = [
            "type": "req",
            "id": id,
            "method": "chat.send",
            "params": params
        ]

        sendJSON(frame)
        NSLog("OpenClaw: sent chat.send (idempotencyKey=\(idempotencyKey))")
        return idempotencyKey
    }

    public func abortChat(runId: String, sessionKey: String? = nil) {
        let key = sessionKey ?? self.sessionKey
        let id = nextRequestId()

        let frame: [String: Any] = [
            "type": "req",
            "id": id,
            "method": "chat.abort",
            "params": [
                "sessionKey": key,
                "runId": runId
            ]
        ]

        sendJSON(frame)
        NSLog("OpenClaw: sent chat.abort (runId=\(runId))")
    }

    private func fireStatusChange() {
        let connected = isConnected
        let authenticated = isAuthenticated
        let pending = isPendingPairing
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(connected, authenticated, pending)
        }
    }

    // MARK: - Private: Listening

    private func startListening() {
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let ws = self.webSocketTask else { return }
                do {
                    let message = try await ws.receive()
                    self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        NSLog("OpenClaw: WebSocket receive error: \(error.localizedDescription)")
                        self.handleDisconnect(error: error)
                    }
                    return
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "event":
            handleEvent(json)
        case "res":
            handleResponse(json)
        default:
            break
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        switch event {
        case "connect.challenge":
            handleConnectChallenge(payload)

        case "chat":
            handleChatEvent(payload)

        case "tick":
            break

        default:
            break
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        let ok = json["ok"] as? Bool ?? false
        let payload = json["payload"] as? [String: Any] ?? [:]

        if ok {
            if let payloadType = payload["type"] as? String, payloadType == "hello-ok" {
                isAuthenticated = true
                reconnectAttempt = 0
                isPendingPairing = false
                NSLog("OpenClaw: authenticated successfully")
                fireStatusChange()
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.openClawDidConnect()
                }
            }
        } else {
            if let errorDict = json["error"] as? [String: Any] {
                let code = errorDict["code"] as? String ?? "?"
                let message = errorDict["message"] as? String ?? "unknown"
                NSLog("OpenClaw: request failed: [\(code)] \(message)")

                if code == "NOT_PAIRED" {
                    if !isPendingPairing {
                        isPendingPairing = true
                        NSLog("OpenClaw: device pending approval — run 'openclaw devices approve' to pair. Will retry automatically.")
                        fireStatusChange()
                    }
                    // Don't schedule here — handleDisconnect will fire from the server closing the socket
                }
            } else {
                NSLog("OpenClaw: request failed: \(json)")
            }
        }
    }

    // MARK: - Private: Protocol Handlers

    private func handleConnectChallenge(_ payload: [String: Any]) {
        let nonce = payload["nonce"] as? String ?? ""
        NSLog("OpenClaw: received connect.challenge (nonce=\(nonce.prefix(8))...)")

        let id = nextRequestId()
        let clientId = "openclaw-macos"
        let clientMode = "cli"
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]
        let signedAt = Int(Date().timeIntervalSince1970 * 1000)

        // Build v2 signature payload:
        // v2|<deviceId>|<clientId>|<clientMode>|<role>|<scopes>|<signedAtMs>|<token>|<nonce>
        let scopesStr = scopes.joined(separator: ",")
        let sigPayload = "v2|\(deviceIdentity.deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopesStr)|\(signedAt)|\(token)|\(nonce)"

        guard let sigPayloadData = sigPayload.data(using: .utf8),
              let signature = deviceIdentity.sign(sigPayloadData) else {
            NSLog("OpenClaw: failed to sign connect challenge")
            return
        }

        var auth: [String: Any] = ["token": token]
        if let password = password, !password.isEmpty {
            auth["password"] = password
        }

        let frame: [String: Any] = [
            "type": "req",
            "id": id,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "role": role,
                "scopes": scopes,
                "client": [
                    "id": clientId,
                    "displayName": "Super Voice Assistant",
                    "version": "1.0.0",
                    "platform": "macos",
                    "mode": clientMode
                ],
                "device": [
                    "id": deviceIdentity.deviceId,
                    "publicKey": deviceIdentity.publicKeyBase64URL,
                    "signature": signature,
                    "signedAt": signedAt,
                    "nonce": nonce
                ],
                "auth": auth
            ] as [String: Any]
        ]

        sendJSON(frame)
    }

    private func handleChatEvent(_ payload: [String: Any]) {
        guard let state = payload["state"] as? String,
              let runId = payload["runId"] as? String else { return }

        let seq = payload["seq"] as? Int ?? 0

        switch state {
        case "delta", "final":
            let text = extractText(from: payload)
            if state == "delta" {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.openClawDidReceiveDelta(runId: runId, text: text, seq: seq)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.openClawDidReceiveFinal(runId: runId, text: text, seq: seq)
                }
            }

        case "error":
            let errorMessage = payload["errorMessage"] as? String ?? "Unknown error"
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.openClawDidReceiveError(runId: runId, message: errorMessage)
            }

        case "aborted":
            let partialText = extractText(from: payload)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.openClawDidReceiveAborted(runId: runId, partialText: partialText.isEmpty ? nil : partialText)
            }

        default:
            break
        }
    }

    private func extractText(from payload: [String: Any]) -> String {
        guard let message = payload["message"] as? [String: Any] else { return "" }

        // Content can be an array of content blocks or a direct text field
        if let content = message["content"] as? [[String: Any]] {
            return content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
        }

        if let text = message["text"] as? String {
            return text
        }

        return ""
    }

    // MARK: - Private: Helpers

    private func nextRequestId() -> String {
        requestCounter += 1
        return "req-\(requestCounter)"
    }

    private func sendJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            NSLog("OpenClaw: failed to serialize JSON")
            return
        }

        webSocketTask?.send(.string(string)) { error in
            if let error = error {
                NSLog("OpenClaw: send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Reconnection

    private func handleDisconnect(error: Error?) {
        let wasAuthenticated = isAuthenticated
        isConnected = false
        isAuthenticated = false
        webSocketTask = nil
        fireStatusChange()

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.openClawDidDisconnect(error: error)
        }

        // Reconnect if we were authenticated, or if we're waiting for pairing approval
        if shouldReconnect && (wasAuthenticated || isPendingPairing) {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        let maxAttempts = isPendingPairing ? 60 : maxReconnectAttempt  // Keep trying longer during pairing
        guard reconnectAttempt < maxAttempts else {
            NSLog("OpenClaw: max reconnect attempts reached")
            isPendingPairing = false
            fireStatusChange()
            return
        }

        let delay = isPendingPairing ? 5.0 : min(pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        if !isPendingPairing {
            NSLog("OpenClaw: reconnecting in \(delay)s (attempt \(reconnectAttempt))")
        }

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenClawManager: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("OpenClaw: WebSocket opened")
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        NSLog("OpenClaw: WebSocket closed (code=\(closeCode.rawValue))")
        handleDisconnect(error: nil)
    }
}
