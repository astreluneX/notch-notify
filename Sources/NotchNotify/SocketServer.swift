import Foundation
import AppKit

/// Handles two payload types on the same Unix socket:
///  - type=notify  → fire-and-forget bubble (existing behavior)
///  - type=request → blocking permission request; server keeps the socket open
///                    until the UI resolves it, then writes {"decision":"..."} back.
final class SocketServer {
    private let store: NotificationStore
    private weak var panel: NotchPanel?
    private var listenSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "notch-notify.socket", qos: .userInitiated)
    private let socketPath: String

    init(store: NotificationStore, panel: NotchPanel) {
        self.store = store
        self.panel = panel
        let dir = NSString(string: "~/Library/Application Support/NotchNotify").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.socketPath = "\(dir)/notch.sock"
    }

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: 1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
                _ = pathBytes.withUnsafeBufferPointer { buf in
                    memcpy(cptr, buf.baseAddress, min(buf.count, 104))
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard bindResult == 0 else {
            let err = errno; close(fd)
            throw NSError(domain: "bind", code: Int(err))
        }
        guard listen(fd, 16) == 0 else {
            let err = errno; close(fd)
            throw NSError(domain: "listen", code: Int(err))
        }
        chmod(socketPath, 0o600)
        listenFD = fd
        NSLog("NotchNotify listening on \(socketPath)")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        listenSource = source
    }

    private func accept() {
        var clientAddr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = Darwin.accept(listenFD, &clientAddr, &len)
        guard client >= 0 else { return }
        queue.async { [weak self] in self?.handleClient(client) }
    }

    private func handleClient(_ fd: Int32) {
        // Read up to newline or 512 KiB
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            if buffer.count > 512 * 1024 { break }
            if buffer.contains(0x0A) { break }
        }
        guard !buffer.isEmpty else { close(fd); return }
        guard let obj = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
            close(fd); return
        }
        let type = (obj["type"] as? String) ?? "notify"
        if type == "request" {
            handleRequest(obj: obj, clientFD: fd)
        } else {
            handleNotify(obj: obj)
            close(fd)
        }
    }

    // MARK: - notify

    private func handleNotify(obj: [String: Any]) {
        guard FeatureToggle.shared.isEnabled else { return }
        let kind = (obj["kind"] as? String) ?? "notification"
        let title = (obj["title"] as? String) ?? "Claude"
        let body = (obj["body"] as? String) ?? ""
        let source = (obj["source"] as? String) ?? "claude-code"
        let sourceApp = obj["sourceApp"] as? String
        let ts = (obj["timestamp"] as? TimeInterval) ?? Date().timeIntervalSince1970
        let evt = NotchEvent(kind: kind, title: title, body: body, source: source, sourceApp: sourceApp, timestamp: ts)
        store.push(evt)
        DispatchQueue.main.async { [weak self] in self?.panel?.showNotify() }
    }

    // MARK: - request

    private func handleRequest(obj: [String: Any], clientFD: Int32) {
        // Feature toggle off → let Claude fall back to its terminal prompt.
        // Silent so the bridge doesn't spawn a system notification when disabled.
        if !FeatureToggle.shared.isEnabled {
            reply(fd: clientFD, decision: .passthrough, silent: true)
            return
        }
        let requestId = (obj["requestId"] as? String) ?? UUID().uuidString
        let toolName = (obj["tool"] as? String) ?? "Bash"
        let sourceApp = obj["sourceApp"] as? String
        let ts = (obj["timestamp"] as? TimeInterval) ?? Date().timeIntervalSince1970

        let toolInput = (obj["toolInput"] as? [String: Any]) ?? [:]
        let cwd = obj["cwd"] as? String ?? (toolInput["cwd"] as? String)

        // Different tools name their target field differently. Normalize into filePath so
        // downstream (risk / glob / bubble body) has a single source of truth.
        let unifiedPath = (toolInput["file_path"] as? String)
            ?? (toolInput["path"] as? String)         // Grep / Glob / Read (list dir)
            ?? (toolInput["pattern"] as? String)      // Glob
            ?? (toolInput["url"] as? String)          // WebFetch
        let tool = ToolContext(
            name: toolName,
            cwd: cwd,
            command: toolInput["command"] as? String,
            filePath: unifiedPath,
            oldString: toolInput["old_string"] as? String,
            newString: toolInput["new_string"] as? String,
            content: toolInput["content"] as? String,
            description: toolInput["description"] as? String
                ?? (toolInput["query"] as? String)    // WebSearch / Grep query
        )
        let diff = computeDiff(tool: tool)
        let assessment = RiskAnalyzer.assess(tool: tool, diff: diff)
        let glob = GlobBuilder.suggest(tool: tool)

        // Auto-allow via session / always store
        if PermissionStore.shared.matchesSession(glob) {
            reply(fd: clientFD, decision: .allowSession, silent: true)
            return
        }

        // Build event
        let title: String
        switch assessment.form {
        case .danger: title = "Claude 请求高风险操作"
        case .expanded: title = "Claude 请求确认（较大改动）"
        case .collapsed: title = "Claude 请求授权"
        }
        let body = tool.command ?? tool.filePath ?? tool.description ?? ""
        let evt = NotchEvent(
            requestId: requestId,
            kind: "request",
            title: title, body: body,
            source: "claude-code",
            sourceApp: sourceApp, timestamp: ts,
            tool: tool,
            risk: assessment.level, form: assessment.form,
            diff: diff, riskNotes: assessment.notes.isEmpty ? nil : assessment.notes,
            suggestedGlob: glob
        )

        let pending = PendingRequest(requestId: requestId)
        PendingRegistry.shared.register(pending)

        store.push(evt)
        DispatchQueue.main.async { [weak self] in
            self?.panel?.showRequest(pending: pending, initialForm: assessment.form)
        }

        // Block this client until UI resolves (max 30s to match panel timeout).
        let decision = pending.wait(timeout: 32)
        _ = PendingRegistry.shared.take(requestId)
        reply(fd: clientFD, decision: decision, silent: false)
    }

    private func reply(fd: Int32, decision: PendingRequest.Decision, silent: Bool) {
        let payload: [String: Any] = [
            "decision": decision.rawValue,
            "silent": silent
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            _ = data.withUnsafeBytes { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            let nl: [UInt8] = [0x0A]
            _ = nl.withUnsafeBufferPointer { write(fd, $0.baseAddress, 1) }
        }
        close(fd)
    }

    private func computeDiff(tool: ToolContext) -> DiffStat? {
        if tool.name == "Edit", let old = tool.oldString, let new = tool.newString {
            let addedLines = new.split(separator: "\n").count
            let removedLines = old.split(separator: "\n").count
            return DiffStat(added: addedLines, removed: removedLines, hunks: 1)
        }
        if tool.name == "Write", let content = tool.content {
            return DiffStat(added: content.split(separator: "\n").count, removed: 0, hunks: 1)
        }
        return nil
    }
}
