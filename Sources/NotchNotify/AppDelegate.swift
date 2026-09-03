import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var socketServer: SocketServer!
    private var statusItem: NSStatusItem!
    let store = NotificationStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(store: store)
        panel.orderOut(nil)

        socketServer = SocketServer(store: store, panel: panel)
        do {
            try socketServer.start()
        } catch {
            NSLog("NotchNotify socket start failed: \(error)")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.toolTip = "NotchNotify"
        }
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test notify (Notification/Stop 样式)", action: #selector(testNotify), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Test request · Bash safe (collapsed)", action: #selector(testBashSafe), keyEquivalent: "1"))
        menu.addItem(NSMenuItem(title: "Test request · Bash danger (rm -rf)", action: #selector(testBashDanger), keyEquivalent: "2"))
        menu.addItem(NSMenuItem(title: "Test request · Edit small (collapsed)", action: #selector(testEditSmall), keyEquivalent: "3"))
        menu.addItem(NSMenuItem(title: "Test request · Edit large (expanded)", action: #selector(testEditLarge), keyEquivalent: "4"))
        menu.addItem(NSMenuItem(title: "Test request · Write overwrite (danger)", action: #selector(testWriteOverwrite), keyEquivalent: "5"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Hide bubble", action: #selector(hideNow), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Quit NotchNotify", action: #selector(quitApp), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        refreshToggleUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshToggleUI),
            name: FeatureToggle.didChange, object: nil)
    }

    @objc private func toggleEnabled() {
        FeatureToggle.shared.isEnabled.toggle()
    }

    @objc private func refreshToggleUI() {
        let enabled = FeatureToggle.shared.isEnabled
        statusItem.button?.title = enabled ? "🔔" : "🔕"
        if let item = statusItem.menu?.items.first {
            item.state = enabled ? .on : .off
        }
        // When disabled, retract any bubble that's mid-flight so it doesn't stick.
        if !enabled { panel.orderOut(nil) }
    }

    @objc private func testNotify() {
        let evt = NotchEvent(
            kind: "notification",
            title: "Claude 需要你回答",
            body: "Test bubble — 单向 notify 样式",
            source: "test", sourceApp: "com.apple.Terminal",
            timestamp: Date().timeIntervalSince1970
        )
        store.push(evt)
        panel.showNotify()
    }

    @objc private func testBashSafe() { simulateRequest(tool: "Bash", input: ["command": "git status --porcelain"]) }
    @objc private func testBashDanger() { simulateRequest(tool: "Bash", input: ["command": "rm -rf node_modules dist build .cache"]) }
    @objc private func testEditSmall() {
        simulateRequest(tool: "Edit", input: [
            "file_path": "\(Self.sampleProjectRoot)/README.md",
            "old_string": "version 1.0",
            "new_string": "version 1.1"
        ])
    }
    @objc private func testEditLarge() {
        let old = (1...25).map { "line \($0) old" }.joined(separator: "\n")
        let new = (1...25).map { "line \($0) new content that is different" }.joined(separator: "\n")
        simulateRequest(tool: "Edit", input: [
            "file_path": "\(Self.sampleProjectRoot)/src/Main.swift",
            "old_string": old, "new_string": new
        ])
    }
    @objc private func testWriteOverwrite() {
        simulateRequest(tool: "Write", input: [
            "file_path": "\(Self.sampleProjectRoot)/README.md",
            "content": "# Sample project\n\nOverwritten content."
        ])
    }

    /// Placeholder cwd for the built-in test menu — resolves to whatever project
    /// the user last opened, or a demo path under $HOME if none is set.
    private static let sampleProjectRoot: String = {
        NSString(string: "~/Projects/sample").expandingTildeInPath
    }()

    private func simulateRequest(tool: String, input: [String: Any]) {
        let cwd = Self.sampleProjectRoot
        let payload: [String: Any] = [
            "type": "request",
            "requestId": UUID().uuidString,
            "tool": tool,
            "cwd": cwd,
            "sourceApp": "com.apple.Terminal",
            "toolInput": input,
            "timestamp": Date().timeIntervalSince1970
        ]
        // Speak to our own socket so full pipeline (risk analysis, panel, decision) is exercised.
        DispatchQueue.global().async {
            let sock = NSString(string: "~/Library/Application Support/NotchNotify/notch.sock").expandingTildeInPath
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = sock.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { cptr in
                    _ = bytes.withUnsafeBufferPointer { memcpy(cptr, $0.baseAddress, min($0.count, 104)) }
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
            }
            if ok == 0, let data = try? JSONSerialization.data(withJSONObject: payload) {
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                let nl: [UInt8] = [0x0A]
                _ = nl.withUnsafeBufferPointer { write(fd, $0.baseAddress, 1) }
                // read reply (best-effort)
                var buf = [UInt8](repeating: 0, count: 1024)
                _ = read(fd, &buf, buf.count)
            }
            close(fd)
        }
    }

    @objc private func hideNow() { panel.orderOut(nil) }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
