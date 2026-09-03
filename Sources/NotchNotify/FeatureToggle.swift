import Foundation

/// Global on/off switch backed by UserDefaults so it survives restarts.
/// When disabled:
///   - PreToolUse requests bypass the bubble (Socket replies `passthrough` — Claude
///     falls back to its terminal prompt, so you're never locked out).
///   - Notification / Stop events are dropped silently.
final class FeatureToggle {
    static let shared = FeatureToggle()
    private let key = "NotchNotify.enabled"
    private let defaults = UserDefaults.standard

    /// Broadcast on changes so the menu icon / checkmark refresh live.
    static let didChange = Notification.Name("NotchNotify.FeatureToggle.didChange")

    private init() {
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: key) }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: FeatureToggle.didChange, object: nil)
        }
    }
}
