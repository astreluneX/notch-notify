import Foundation

/// Judges a tool call into safe / action / danger based on well-known heuristics.
/// Kept intentionally minimal — false positives are cheap (user just presses Allow),
/// false negatives are expensive (numb the red state). Err on the side of danger.
enum RiskAnalyzer {

    private static let dangerousCommands: [String] = [
        #"(^|[\s;|&])rm\s+(-[a-zA-Z]*[rRfF][a-zA-Z]*)"#,
        #"(^|[\s;|&])sudo(\s|$)"#,
        #"(^|[\s;|&])git\s+push\s+.*(--force|-f)(\s|$)"#,
        #"(^|[\s;|&])git\s+push\s+--force-with-lease"#,
        #"(^|[\s;|&])git\s+reset\s+--hard"#,
        #"(^|[\s;|&])git\s+clean\s+-[a-zA-Z]*[dfx]"#,
        #"(^|[\s;|&])(drop|truncate)\s+(table|database)"#,
        #"(^|[\s;|&])mkfs\."#,
        #"(^|[\s;|&])dd\s+.*of=/dev/"#,
        #":\s*\(\s*\)\s*\{"#,       // fork bomb prefix
        #"(^|[\s;|&])chmod\s+-R"#,
        #"(^|[\s;|&])chown\s+-R"#,
        #"(^|[\s;|&])curl\s+[^|]*\|\s*(sh|bash|zsh)"#,
        #"(^|[\s;|&])wget\s+[^|]*\|\s*(sh|bash|zsh)"#,
    ]

    private static let sensitiveFilePatterns: [String] = [
        #"\.env(\.|$)"#,
        #"(^|/)\.zshrc$"#,
        #"(^|/)\.bashrc$"#,
        #"(^|/)\.zprofile$"#,
        #"(^|/)\.ssh/"#,
        #"(^|/)\.aws/"#,
        #"(^|/)\.kube/"#,
        #"(^|/)\.claude/settings"#,
        #"(^|/)id_rsa"#,
        #"(^|/)id_ed25519"#,
        #"credentials(\.|$)"#,
        #"secrets?(\.|$)"#,
    ]

    struct Assessment {
        let level: RiskLevel
        let form: BubbleForm
        let notes: [String]
    }

    static func assess(tool: ToolContext, diff: DiffStat?) -> Assessment {
        switch tool.name {
        case "Bash":
            return assessBash(tool.command ?? "", cwd: tool.cwd)
        case "Edit":
            return assessEdit(tool: tool, diff: diff)
        case "Write":
            return assessWrite(tool: tool)
        case "Read", "Grep", "Glob":
            return assessReadOnly(tool: tool)
        case "WebFetch", "WebSearch":
            return Assessment(level: .safe, form: .collapsed, notes: ["Network access — response is read-only"])
        default:
            return Assessment(level: .action, form: .collapsed, notes: [])
        }
    }

    private static func assessReadOnly(tool: ToolContext) -> Assessment {
        let path = tool.filePath ?? ""
        if isSensitiveFile(path) {
            return Assessment(level: .danger, form: .danger,
                              notes: ["Sensitive file — credentials or shell profile"])
        }
        var notes: [String] = []
        if let cwd = tool.cwd, !path.isEmpty, !isInside(path: path, root: cwd) {
            notes.append("Path is outside the project root")
        }
        return Assessment(level: .safe, form: .collapsed, notes: notes)
    }

    // MARK: - Bash

    private static func assessBash(_ cmd: String, cwd: String?) -> Assessment {
        var notes: [String] = []
        for pat in dangerousCommands {
            if cmd.range(of: pat, options: .regularExpression) != nil {
                notes.append("Matches destructive pattern: \(patternDescription(pat))")
                notes.append("Execution is immediate — no dry-run flag detected")
                return Assessment(level: .danger, form: .danger, notes: notes)
            }
        }
        return Assessment(level: .action, form: .collapsed, notes: notes)
    }

    // MARK: - Edit

    private static func assessEdit(tool: ToolContext, diff: DiffStat?) -> Assessment {
        var notes: [String] = []
        let path = tool.filePath ?? ""

        if isSensitiveFile(path) {
            notes.append("Sensitive file — credentials or shell profile")
            return Assessment(level: .danger, form: .danger, notes: notes)
        }
        if let cwd = tool.cwd, !isInside(path: path, root: cwd) {
            notes.append("Path is outside the project root (\(cwd))")
            return Assessment(level: .danger, form: .danger, notes: notes)
        }

        let added = diff?.added ?? 0
        let removed = diff?.removed ?? 0
        let hunks = diff?.hunks ?? 1
        if added + removed > 20 || hunks > 3 {
            return Assessment(level: .action, form: .expanded, notes: notes)
        }
        return Assessment(level: .action, form: .collapsed, notes: notes)
    }

    // MARK: - Write

    private static func assessWrite(tool: ToolContext) -> Assessment {
        var notes: [String] = []
        let path = tool.filePath ?? ""

        if isSensitiveFile(path) {
            notes.append("Sensitive file — credentials or shell profile")
            return Assessment(level: .danger, form: .danger, notes: notes)
        }
        if let cwd = tool.cwd, !isInside(path: path, root: cwd) {
            notes.append("Path is outside the project root (\(cwd))")
            return Assessment(level: .danger, form: .danger, notes: notes)
        }

        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        if exists {
            notes.append("File exists — content will be replaced, not merged")
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 512 {
                notes.append("Current file is \(size) bytes — recovery relies on git")
            }
            return Assessment(level: .danger, form: .danger, notes: notes)
        }
        return Assessment(level: .action, form: .collapsed, notes: notes)
    }

    // MARK: - helpers

    private static func isInside(path: String, root: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let r = (root as NSString).standardizingPath
        return p.hasPrefix(r + "/") || p == r
    }

    private static func isSensitiveFile(_ path: String) -> Bool {
        for pat in sensitiveFilePatterns {
            if path.range(of: pat, options: .regularExpression) != nil { return true }
        }
        return false
    }

    private static func patternDescription(_ pat: String) -> String {
        if pat.contains("rm") { return "rm -rf" }
        if pat.contains("sudo") { return "sudo" }
        if pat.contains("push") { return "git force push" }
        if pat.contains("reset") { return "git reset --hard" }
        if pat.contains("clean") { return "git clean" }
        if pat.contains("drop") { return "SQL drop/truncate" }
        if pat.contains("mkfs") { return "mkfs" }
        if pat.contains("dd") { return "dd overwrite" }
        if pat.contains("chmod") { return "chmod -R" }
        if pat.contains("chown") { return "chown -R" }
        if pat.contains("curl") || pat.contains("wget") { return "curl|bash pipeline" }
        if pat.contains(":") { return "fork bomb" }
        return "destructive"
    }
}

/// Turns a specific tool invocation into a glob for Session/Always allow rules.
enum GlobBuilder {
    static func suggest(tool: ToolContext) -> String {
        switch tool.name {
        case "Bash":
            let cmd = tool.command ?? ""
            let head = cmd.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if head.count >= 2 {
                return "bash(\(head[0]) \(head[1]) *)"
            } else if let first = head.first {
                return "bash(\(first) *)"
            }
            return "bash(*)"
        case "Edit":
            if let path = tool.filePath, let cwd = tool.cwd {
                let rel = pathRelative(path, root: cwd)
                let first = rel.split(separator: "/").first.map(String.init) ?? "**"
                return "edit(\(first)/**)"
            }
            return "edit(**)"
        case "Write":
            if let path = tool.filePath, let cwd = tool.cwd {
                let rel = pathRelative(path, root: cwd)
                let first = rel.split(separator: "/").first.map(String.init) ?? "**"
                return "write(\(first)/**)"
            }
            return "write(**)"
        case "Read", "Grep", "Glob":
            let verb = tool.name.lowercased()
            if let path = tool.filePath ?? tool.cwd {
                let dir = readAncestor(path)
                return "\(verb)(\(dir)/**)"
            }
            return "\(verb)(**)"
        case "WebFetch":
            return "webfetch(*)"
        case "WebSearch":
            return "websearch(*)"
        default:
            return "\(tool.name.lowercased())(*)"
        }
    }

    /// Give read-only tools a coarse allow scope: the top two path segments.
    /// `/Users/alice/projects/demo/scripts/foo.sh` → `/Users/alice/projects`
    /// so a single Session grant covers the whole project the user is browsing.
    private static func readAncestor(_ raw: String) -> String {
        let p = (raw as NSString).standardizingPath
        let parts = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 3 { return "/" + parts.prefix(3).joined(separator: "/") }
        if parts.count >= 2 { return "/" + parts.prefix(2).joined(separator: "/") }
        return p
    }

    private static func pathRelative(_ path: String, root: String) -> String {
        let p = (path as NSString).standardizingPath
        let r = (root as NSString).standardizingPath
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return p
    }
}
