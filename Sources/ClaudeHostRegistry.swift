import Foundation
import Network

/// Tracks which remote LAN hosts are allowed to call Murmur's HTTP API.
///
/// Localhost is always allowed and is never represented here. Remote hosts
/// (by IP) have to be explicitly approved via the Claude settings tab
/// before their requests are processed — until then, requests return 403
/// pending_approval and the IP lands in the ephemeral pending list for the
/// user to review.
///
/// Approved state persists in UserDefaults. Pending state is in-memory only
/// so a hostile LAN host can't fill it permanently.
final class ClaudeHostRegistry {
    static let shared = ClaudeHostRegistry()

    struct ApprovedHost: Codable, Equatable {
        var ip: String
        var label: String
        var approvedAt: Date
    }

    struct PendingHost: Equatable {
        var ip: String
        var label: String?
        var firstSeen: Date
        var attemptCount: Int
    }

    /// Fires when approved or pending lists change. UI subscribes to refresh.
    static let didChangeNotification = Notification.Name("ClaudeHostRegistryDidChange")

    private let defaults: UserDefaults
    private let approvedKey = "claude.approvedHosts"
    private let queue = DispatchQueue(label: "com.murmur.claudeHostRegistry")
    private var _pending: [PendingHost] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Approved hosts

    var approvedHosts: [ApprovedHost] {
        guard let data = defaults.data(forKey: approvedKey),
              let decoded = try? JSONDecoder().decode([ApprovedHost].self, from: data) else {
            return []
        }
        return decoded
    }

    private func writeApproved(_ hosts: [ApprovedHost]) {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: approvedKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func isApproved(ip: String) -> Bool {
        return approvedHosts.contains { $0.ip == ip }
    }

    /// Move an IP from pending → approved. No-op if already approved.
    func approve(ip: String) {
        var approved = approvedHosts
        if approved.contains(where: { $0.ip == ip }) { return }
        let label = queue.sync { _pending.first(where: { $0.ip == ip })?.label }
        approved.append(ApprovedHost(ip: ip, label: label ?? "", approvedAt: Date()))
        writeApproved(approved)
        queue.sync { _pending.removeAll { $0.ip == ip } }
    }

    func remove(ip: String) {
        var approved = approvedHosts
        approved.removeAll { $0.ip == ip }
        writeApproved(approved)
    }

    /// Rename the human-readable label on an already-approved host.
    func updateLabel(ip: String, label: String) {
        var approved = approvedHosts
        guard let idx = approved.firstIndex(where: { $0.ip == ip }) else { return }
        approved[idx].label = label
        writeApproved(approved)
    }

    // MARK: - Pending hosts

    var pendingHosts: [PendingHost] {
        queue.sync { _pending }
    }

    /// Record that an unapproved IP tried to call us. Dedupes by IP, increments
    /// attempt count, and kicks off a reverse-DNS lookup the first time we see
    /// a new IP so the settings list can show a hostname alongside the IP.
    func recordPending(ip: String) {
        // Never enlist localhost or already-approved hosts.
        if Self.isLocalhost(ip: ip) { return }
        if isApproved(ip: ip) { return }

        var didInsert = false
        queue.sync {
            if let idx = _pending.firstIndex(where: { $0.ip == ip }) {
                _pending[idx].attemptCount += 1
            } else {
                _pending.append(PendingHost(ip: ip, label: nil, firstSeen: Date(), attemptCount: 1))
                didInsert = true
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)

        if didInsert {
            resolveHostname(for: ip)
        }
    }

    func denyPending(ip: String) {
        queue.sync { _pending.removeAll { $0.ip == ip } }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func clearAllPending() {
        queue.sync { _pending.removeAll() }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Reverse DNS

    private func resolveHostname(for ip: String) {
        // Off the main thread — getnameinfo can block briefly. Best-effort
        // only; if it fails we just leave the label nil and the UI shows
        // the IP alone.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let hostname = Self.reverseLookup(ip: ip) else { return }
            guard let self = self else { return }
            self.queue.sync {
                if let idx = self._pending.firstIndex(where: { $0.ip == ip }) {
                    self._pending[idx].label = hostname
                }
            }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static func reverseLookup(ip: String) -> String? {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(info) }

        let bufSize = Int(NI_MAXHOST)
        var hostBuf = [CChar](repeating: 0, count: bufSize)
        let rc = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &hostBuf, socklen_t(bufSize), nil, 0, NI_NAMEREQD)
        guard rc == 0 else { return nil }
        let name = String(cString: hostBuf)
        return name.isEmpty || name == ip ? nil : name
    }

    // MARK: - Helpers

    static func isLocalhost(ip: String) -> Bool {
        return ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1"
    }
}
