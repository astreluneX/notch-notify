import Foundation

/// A single-shot decision handle passed from the socket server to the UI.
/// The UI resolves it once, at which point the socket writer wakes up and replies to hook.
final class PendingRequest {
    enum Decision: String, Codable {
        case allowOnce
        case allowSession
        case allowAlways
        case passthrough    // "切回" — user will handle it in the terminal; Claude runs its own permission
        case deny           // kept for programmatic use; not surfaced in UI
        case timeout
    }

    let requestId: String
    private let semaphore = DispatchSemaphore(value: 0)
    private var decision: Decision = .timeout
    private var lock = NSLock()
    private var settled = false

    init(requestId: String) {
        self.requestId = requestId
    }

    func resolve(_ d: Decision) {
        lock.lock()
        if !settled {
            decision = d
            settled = true
            semaphore.signal()
        }
        lock.unlock()
    }

    /// Blocks up to `timeout` seconds; returns the decision (`.timeout` if none arrived).
    func wait(timeout: TimeInterval) -> Decision {
        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { resolve(.timeout) }
        return decision
    }
}

/// Global registry: bubble UI looks up a PendingRequest by requestId to resolve it.
final class PendingRegistry {
    static let shared = PendingRegistry()
    private var map: [String: PendingRequest] = [:]
    private let lock = NSLock()

    func register(_ req: PendingRequest) {
        lock.lock(); map[req.requestId] = req; lock.unlock()
    }
    func take(_ id: String) -> PendingRequest? {
        lock.lock(); defer { lock.unlock() }
        let r = map[id]; map.removeValue(forKey: id); return r
    }
    func peek(_ id: String) -> PendingRequest? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }
}
