import AppKit
import SwiftUI

/// Coordinates one floating panel per attached NSScreen so the bubble is visible
/// on both the built-in display and any external monitors simultaneously.
/// Public API (showNotify / showRequest / orderOut) stays compatible with the
/// original single-panel version so AppDelegate and SocketServer are unchanged.
final class NotchPanel {
    private let store: NotificationStore
    /// Pair each panel with the NSScreen it's intended to sit on. `panel.screen`
    /// returns nil on freshly-created hidden panels (or drifts to NSScreen.main
    /// which follows mouse focus), so we track the target explicitly.
    private var panels: [(screen: NSScreen, panel: NSPanel)] = []
    private var hideTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var currentPending: PendingRequest?
    private var currentForm: BubbleForm = .collapsed
    private var lastSize: CGSize = .zero

    init(store: NotificationStore) {
        self.store = store
        buildPanels()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API (matches the previous NSPanel subclass)

    func showNotify() {
        currentPending = nil
        currentForm = .collapsed
        rebuildHosting()
        layout(size: CGSize(width: 380, height: 96))
        fadeIn()
        armTimeout(seconds: 12) { [weak self] in self?.hideBubble() }
        installKeyMonitor()
    }

    func showRequest(pending: PendingRequest, initialForm: BubbleForm) {
        currentPending = pending
        currentForm = initialForm
        rebuildHosting()
        layout(size: sizeFor(form: initialForm))
        fadeIn()
        armTimeout(seconds: 30) { [weak self] in self?.resolvePending(.timeout) }
        installKeyMonitor()
    }

    /// AppDelegate calls this at launch and via the tray menu "Hide bubble".
    func orderOut(_ sender: Any?) {
        hideTimer?.invalidate()
        for entry in panels { entry.panel.orderOut(sender) }
    }

    // MARK: - Panel factory

    private func buildPanels() {
        panels.removeAll()
        for screen in NSScreen.screens {
            let p = makePanel(for: screen)
            panels.append((screen: screen, panel: p))
        }
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 560, height: 120)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    @objc private func screensChanged() {
        let wasVisible = panels.contains(where: { $0.panel.isVisible })
        for entry in panels { entry.panel.orderOut(nil) }
        buildPanels()
        if wasVisible {
            rebuildHosting()
            layout(size: lastSize == .zero ? sizeFor(form: currentForm) : lastSize)
            fadeIn()
        }
    }

    // MARK: - Content wiring

    private func rebuildHosting() {
        let form = currentForm
        for entry in panels {
            let hosting = NSHostingView(rootView: BubbleView(
                store: store,
                onDecision: { [weak self] d in self?.resolvePending(d) },
                onExpand: { [weak self] in self?.reflow(form: .expanded) },
                onCollapse: { [weak self] in self?.reflow(form: .collapsed) },
                onDismiss: { [weak self] in self?.hideBubble() },
                onClickBack: { [weak self] in self?.activateSenderThenHide() },
                forcedForm: form
            ))
            hosting.autoresizingMask = [.width, .height]
            entry.panel.contentView = hosting
        }
    }

    private func reflow(form: BubbleForm) {
        currentForm = form
        rebuildHosting()
        layout(size: sizeFor(form: form))
    }

    private func sizeFor(form: BubbleForm) -> CGSize {
        switch form {
        case .collapsed: return CGSize(width: 560, height: 76)
        case .expanded: return CGSize(width: 540, height: 340)
        case .danger: return CGSize(width: 540, height: 260)
        }
    }

    // MARK: - Positioning / animation

    private func layout(size: CGSize) {
        lastSize = size
        for entry in panels {
            let frame = entry.screen.frame
            let x = frame.midX - size.width / 2
            let y = frame.maxY - size.height - 10
            entry.panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                                 display: true, animate: false)
        }
    }

    private func fadeIn() {
        for entry in panels {
            entry.panel.alphaValue = 0
            entry.panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            for entry in self.panels { entry.panel.animator().alphaValue = 1 }
        }
    }

    // MARK: - Timers / keys

    private func armTimeout(seconds: TimeInterval, then: @escaping () -> Void) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in then() }
    }

    private func installKeyMonitor() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return event
        }
    }

    private var anyPanelVisible: Bool { panels.contains { $0.panel.isVisible } }

    private func handleKey(_ event: NSEvent) {
        guard anyPanelVisible else { return }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.keyCode
        if key == 36 || key == 76 {
            if currentPending != nil {
                if mods.contains(.command) { resolvePending(.allowAlways); return }
                if mods.contains(.option) { resolvePending(.allowSession); return }
                if currentForm == .danger {
                    if mods.contains(.command) { resolvePending(.allowOnce) }
                    return
                }
                resolvePending(.allowOnce)
                return
            } else {
                activateSenderThenHide()
                return
            }
        }
        if key == 53 {
            if currentPending != nil {
                activateSenderThenHide()
                resolvePending(.passthrough)
            } else {
                hideBubble()
            }
            return
        }
        if key == 40 && mods.contains(.command) && currentPending != nil {
            reflow(form: currentForm == .expanded ? .collapsed : .expanded)
            return
        }
    }

    // MARK: - Decision handling

    private func resolvePending(_ d: PendingRequest.Decision) {
        guard let pending = currentPending else { hideBubble(); return }
        if let evt = store.current, let glob = evt.suggestedGlob {
            switch d {
            case .allowSession:
                PermissionStore.shared.allowForSession(glob)
            case .allowAlways:
                _ = PermissionStore.shared.allowAlways(glob)
            default: break
            }
        }
        pending.resolve(d)
        currentPending = nil
        hideBubble()
    }

    private func hideBubble() {
        hideTimer?.invalidate()
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            for entry in self.panels { entry.panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for entry in self.panels { entry.panel.orderOut(nil) }
            self.store.clearCurrent()
        })
    }

    // MARK: - Activate caller

    private func activateSenderThenHide() {
        let bundleID = store.current?.sourceApp ?? ""
        activate(bundleID: bundleID)
        hideBubble()
    }

    private func activate(bundleID: String) {
        if !bundleID.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                    if let err = err { NSLog("NotchNotify openApplication error: \(err)") }
                }
                return
            }
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }
        let fallback = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.alacritty",
            "com.microsoft.VSCode", "com.jetbrains.intellij", "com.jetbrains.intellij.ce"
        ]
        for id in fallback {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               NSRunningApplication.runningApplications(withBundleIdentifier: id).first != nil {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
                return
            }
        }
    }
}
