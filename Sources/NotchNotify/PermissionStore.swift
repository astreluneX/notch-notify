import Foundation

/// Manages Session-scope (memory-only) and Always-scope (settings.json) allow rules.
/// Any matcher for a request that hits a session/always rule is auto-allowed without a bubble.
final class PermissionStore {
    static let shared = PermissionStore()

    private var sessionGlobs = Set<String>()
    private let queue = DispatchQueue(label: "notch-notify.permstore", attributes: .concurrent)

    // MARK: - Session

    func allowForSession(_ glob: String) {
        queue.async(flags: .barrier) { self.sessionGlobs.insert(glob) }
    }

    func matchesSession(_ glob: String) -> Bool {
        var hit = false
        queue.sync { hit = sessionGlobs.contains(glob) }
        return hit
    }

    // MARK: - Always (writes to ~/.claude/settings.json)

    /// Appends the glob into permissions.allow. Idempotent.
    /// Returns nil on success, error string on failure.
    @discardableResult
    func allowAlways(_ glob: String) -> String? {
        let path = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        let fm = FileManager.default
        do {
            var root: [String: Any] = [:]
            if fm.fileExists(atPath: path),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = obj
            }
            var perms = (root["permissions"] as? [String: Any]) ?? [:]
            var allow = (perms["allow"] as? [String]) ?? []
            if !allow.contains(glob) { allow.append(glob) }
            perms["allow"] = allow
            root["permissions"] = perms

            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // atomic write
            let tmp = path + ".tmp"
            try out.write(to: URL(fileURLWithPath: tmp))
            _ = try? fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
            return nil
        } catch {
            return "\(error)"
        }
    }
}
