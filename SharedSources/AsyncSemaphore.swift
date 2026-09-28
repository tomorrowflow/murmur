import Foundation

/// Minimal counting semaphore for async code.
///
/// `DispatchSemaphore.wait()` must never be called from a task on the
/// cooperative pool — it blocks the underlying thread, and the pool has only
/// as many threads as there are cores. This suspends instead.
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.permits = value
    }

    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Fire-and-forget release, usable from a synchronous `defer`.
    public nonisolated func signalDetached() {
        Task { await self.signal() }
    }

    public func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
