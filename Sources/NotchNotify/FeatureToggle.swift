import Foundation

/// Global on/off switches backed by UserDefaults so they survive restarts.
///
/// `isEnabled` is the master switch. When disabled:
///   - PreToolUse requests bypass the bubble (Socket replies `passthrough` — Claude
///     falls back to its terminal prompt, so you're never locked out).
///   - Notification / Stop events are dropped silently.
///
/// `autoApprove` is a separate opt-in: when it and `isEnabled` are both on, a tool
/// request whose risk level is in `autoApproveLevels` is approved immediately
/// without showing a bubble. Levels not selected still prompt as usual, so you can
/// auto-approve `safe` / `action` while keeping `danger` gated.
///
/// `autoApproveHidesNotifications` also silences Notification / Stop bubbles while
/// auto-approve is active.
final class FeatureToggle {
    static let shared = FeatureToggle()
    private let key = "NotchNotify.enabled"
    private let autoApproveKey = "NotchNotify.autoApprove"
    private let autoApproveLevelsKey = "NotchNotify.autoApproveLevels"
    private let autoApproveHidesNotificationsKey = "NotchNotify.autoApproveHidesNotifications"
    private let defaults = UserDefaults.standard

    /// Broadcast on changes so the menu icon / checkmarks refresh live.
    static let didChange = Notification.Name("NotchNotify.FeatureToggle.didChange")

    /// Risk levels selectable for auto-approve, ordered least → most risky.
    static let allLevels: [RiskLevel] = [.safe, .action, .danger]

    private init() {
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
        if defaults.object(forKey: autoApproveKey) == nil {
            defaults.set(false, forKey: autoApproveKey)
        }
        if defaults.object(forKey: autoApproveLevelsKey) == nil {
            // Default to everything except danger — false positives are cheap,
            // false negatives (rm -rf, force push, credential files) are not.
            defaults.set([RiskLevel.safe.rawValue, RiskLevel.action.rawValue],
                         forKey: autoApproveLevelsKey)
        }
        if defaults.object(forKey: autoApproveHidesNotificationsKey) == nil {
            defaults.set(true, forKey: autoApproveHidesNotificationsKey)
        }
    }

    private func publish() {
        NotificationCenter.default.post(name: FeatureToggle.didChange, object: nil)
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: key) }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: key)
            publish()
        }
    }

    var autoApprove: Bool {
        get { defaults.bool(forKey: autoApproveKey) }
        set {
            guard newValue != autoApprove else { return }
            defaults.set(newValue, forKey: autoApproveKey)
            publish()
        }
    }

    var autoApproveLevels: Set<RiskLevel> {
        get {
            let raw = defaults.stringArray(forKey: autoApproveLevelsKey) ?? []
            return Set(raw.compactMap(RiskLevel.init(rawValue:)))
        }
        set {
            guard newValue != autoApproveLevels else { return }
            let raw = FeatureToggle.allLevels
                .filter { newValue.contains($0) }
                .map { $0.rawValue }
            defaults.set(raw, forKey: autoApproveLevelsKey)
            publish()
        }
    }

    var autoApproveHidesNotifications: Bool {
        get { defaults.bool(forKey: autoApproveHidesNotificationsKey) }
        set {
            guard newValue != autoApproveHidesNotifications else { return }
            defaults.set(newValue, forKey: autoApproveHidesNotificationsKey)
            publish()
        }
    }

    /// True when auto-approve is currently active (master + auto switches both on).
    var isAutoApproving: Bool { isEnabled && autoApprove }

    /// Should a request of this risk level be approved without a bubble?
    func shouldAutoApprove(level: RiskLevel) -> Bool {
        isAutoApproving && autoApproveLevels.contains(level)
    }
}
