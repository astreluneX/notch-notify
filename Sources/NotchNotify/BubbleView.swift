import SwiftUI

// MARK: - Root switcher

struct BubbleView: View {
    @ObservedObject var store: NotificationStore
    let onDecision: (PendingRequest.Decision) -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onDismiss: () -> Void
    let onClickBack: () -> Void
    var forcedForm: BubbleForm? = nil

    var body: some View {
        Group {
            if let evt = store.current, evt.kind == "request", let tool = evt.tool {
                let form = forcedForm ?? evt.form ?? .collapsed
                switch form {
                case .collapsed:
                    CollapsedRequestBubble(event: evt, tool: tool,
                                            onAllowOnce: { onDecision(.allowOnce) },
                                            onAllowSession: { onDecision(.allowSession) },
                                            onSwitch: { onClickBack(); onDecision(.passthrough) },
                                            onExpand: onExpand)
                case .expanded:
                    ExpandedRequestBubble(event: evt, tool: tool,
                                           onAllowOnce: { onDecision(.allowOnce) },
                                           onAllowSession: { onDecision(.allowSession) },
                                           onAllowAlways: { onDecision(.allowAlways) },
                                           onSwitch: { onClickBack(); onDecision(.passthrough) },
                                           onCollapse: onCollapse)
                case .danger:
                    DangerRequestBubble(event: evt, tool: tool,
                                         onAllow: { onDecision(.allowOnce) },
                                         onSwitch: { onClickBack(); onDecision(.passthrough) })
                }
            } else if let evt = store.current {
                NotifyBubble(event: evt, onDismiss: onDismiss, onClickBack: onClickBack)
            }
        }
    }
}

// MARK: - Notify (existing single-line bubble, kept for Notification / Stop)

private struct NotifyBubble: View {
    let event: NotchEvent
    let onDismiss: () -> Void
    let onClickBack: () -> Void

    var body: some View {
        ZStack {
            BubbleBackground()
            HStack(spacing: 12) {
                Circle()
                    .fill(colorFor(kind: event.kind))
                    .frame(width: 10, height: 10)
                    .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(event.body)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    Button(action: onClickBack) {
                        Text("切回")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }.buttonStyle(.plain)
                    Button(action: onDismiss) {
                        Text("忽略").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                    }.buttonStyle(.plain)
                }
                .padding(.trailing, 6)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { onClickBack() }
    }

    private func colorFor(kind: String) -> Color {
        switch kind {
        case "stop": return .green
        case "prompt-submit": return .blue
        default: return .orange
        }
    }
}

// MARK: - Collapsed request

private struct CollapsedRequestBubble: View {
    let event: NotchEvent
    let tool: ToolContext
    let onAllowOnce: () -> Void
    let onAllowSession: () -> Void
    let onSwitch: () -> Void
    let onExpand: () -> Void

    private static let sessionColor = Color(red: 0.34, green: 0.62, blue: 1.0)
    private static let onceColor = Color(red: 0.19, green: 0.82, blue: 0.35)

    var body: some View {
        ZStack {
            BubbleBackground()
            HStack(spacing: 10) {
                ToolIcon(name: tool.name)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(tool.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                        Text("·").foregroundColor(.white.opacity(0.3))
                        Text(shortenPath(pathHint())).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    detailLine.lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Button(action: onSwitch) {
                        Text("切回").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    Button(action: onAllowOnce) {
                        HStack(spacing: 3) {
                            Text("Once").font(.system(size: 12, weight: .semibold)).foregroundColor(Self.onceColor)
                            Text("⏎").font(.system(size: 9.5, design: .monospaced)).foregroundColor(Self.onceColor.opacity(0.7))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Self.onceColor.opacity(0.14)))
                    }.buttonStyle(.plain)
                    Button(action: onAllowSession) {
                        HStack(spacing: 3) {
                            Text("Session").font(.system(size: 12, weight: .semibold)).foregroundColor(Self.sessionColor)
                            Text("⌥⏎").font(.system(size: 9.5, design: .monospaced)).foregroundColor(Self.sessionColor.opacity(0.7))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Self.sessionColor.opacity(0.14)))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onExpand() }
    }

    @ViewBuilder private var detailLine: some View {
        switch tool.name {
        case "Bash":
            Text(tool.command ?? "")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(.white)
        case "Edit":
            HStack(spacing: 6) {
                if let d = event.diff {
                    Text("+\(d.added)").foregroundColor(Color(red: 0.19, green: 0.82, blue: 0.35))
                    Text("−\(d.removed)").foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                    Text("in \(d.hunks) hunk\(d.hunks == 1 ? "" : "s")").foregroundColor(.white.opacity(0.5))
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
        case "Write":
            Text("new file · \((tool.content ?? "").split(separator: "\n").count) lines")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        default:
            Text(event.body).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
        }
    }

    private func pathHint() -> String {
        if let p = tool.filePath { return relativize(p, cwd: tool.cwd) }
        if let cwd = tool.cwd { return (cwd as NSString).lastPathComponent }
        return ""
    }
}

// MARK: - Expanded request

private struct ExpandedRequestBubble: View {
    let event: NotchEvent
    let tool: ToolContext
    let onAllowOnce: () -> Void
    let onAllowSession: () -> Void
    let onAllowAlways: () -> Void
    let onSwitch: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        ZStack {
            BubbleBackground()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(tool.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    Text(relativize(tool.filePath ?? "", cwd: tool.cwd))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                    }.buttonStyle(.plain)
                }

                if tool.name == "Bash" {
                    Text(tool.command ?? "")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
                }

                if let d = event.diff {
                    HStack(spacing: 6) {
                        Text("+\(d.added)").foregroundColor(Color(red: 0.19, green: 0.82, blue: 0.35))
                        Text("−\(d.removed)").foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                        Text("across \(d.hunks) hunks").foregroundColor(.white.opacity(0.5))
                    }
                    .font(.system(size: 12, design: .monospaced))
                }

                if tool.name == "Edit", let oldS = tool.oldString, let newS = tool.newString {
                    DiffPreview(oldString: oldS, newString: newS)
                }

                HStack(spacing: 6) {
                    tier("Once", hint: "This call only", key: "⏎", primary: true, action: onAllowOnce)
                    tier("Session", hint: "Until Claude quits", key: "⌥⏎", primary: false, action: onAllowSession)
                    tier("Always", hint: "Write to settings.json", key: "⌘⏎", primary: false, action: onAllowAlways)
                }

                HStack {
                    Button(action: onSwitch) {
                        HStack(spacing: 4) {
                            Text("切回").font(.system(size: 12.5))
                            Text("⎋").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.35))
                        }.foregroundColor(.white.opacity(0.7))
                    }.buttonStyle(.plain)
                    Spacer()
                    if let g = event.suggestedGlob {
                        (Text("Session & Always match ").foregroundColor(.white.opacity(0.4)) +
                         Text(g).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.7)))
                            .font(.system(size: 11.5))
                    }
                }
                .padding(.top, 8)
            }
            .padding(16)
        }
    }

    private func tier(_ label: String, hint: String, key: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primary ? Color(red: 0.19, green: 0.82, blue: 0.35) : .white)
                    Text(hint).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(primary ? Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.14) : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                    primary ? Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1))

                Text(key).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.4)))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Danger request

private struct DangerRequestBubble: View {
    let event: NotchEvent
    let tool: ToolContext
    let onAllow: () -> Void
    let onSwitch: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.4), lineWidth: 1)
                )
                .shadow(color: Color(red: 1, green: 0.27, blue: 0.23).opacity(0.28), radius: 22, x: 0, y: 14)

            HStack(spacing: 0) {
                Rectangle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    // header
                    HStack(spacing: 8) {
                        Text(dangerFlag)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.15)))
                        Text(tool.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                        Spacer()
                        Text(pathHint())
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                    .overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .bottom)

                    // command / body
                    if let cmd = tool.command, !cmd.isEmpty {
                        Text(cmd)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Color(red: 1, green: 0.92, blue: 0.91))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.2), lineWidth: 1))
                            .padding(.horizontal, 16).padding(.top, 12)
                    } else if let path = tool.filePath, tool.name == "Write" {
                        Text("replaces \(path)")
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundColor(Color(red: 1, green: 0.92, blue: 0.91))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.08)))
                            .padding(.horizontal, 16).padding(.top, 12)
                    }

                    // risk notes
                    if let notes = event.riskNotes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(notes, id: \.self) { n in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(Color(red: 1, green: 0.62, blue: 0.04))
                                        .frame(width: 4, height: 4).offset(y: 6)
                                    Text(n).font(.system(size: 12)).foregroundColor(.white.opacity(0.65)).lineLimit(3)
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.top, 12)
                    }

                    // footer
                    HStack(spacing: 8) {
                        Button(action: onSwitch) {
                            HStack(spacing: 6) {
                                Text("切回处理").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                                Text("⎋").font(.system(size: 10.5, design: .monospaced)).foregroundColor(.white.opacity(0.6))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                        }.buttonStyle(.plain)
                        Button(action: onAllow) {
                            HStack(spacing: 6) {
                                Text(tool.name == "Write" ? "Overwrite" : "Allow once")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                                Text("⌘⏎").font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(Color(red: 1, green: 0.27, blue: 0.23))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.12)))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.35), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
                    .background(Color.black.opacity(0.2))
                }
            }
        }
    }

    private var dangerFlag: String {
        switch tool.name {
        case "Write": return "OVERWRITE"
        case "Edit": return "SENSITIVE"
        case "Bash": return "DESTRUCTIVE"
        default: return "DANGER"
        }
    }
    private func pathHint() -> String {
        if let p = tool.filePath { return relativize(p, cwd: tool.cwd) }
        if let cwd = tool.cwd { return (cwd as NSString).lastPathComponent }
        return ""
    }
}

// MARK: - Diff preview

private struct DiffPreview: View {
    let oldString: String
    let newString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("preview").font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4)).textCase(.uppercase)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Spacer()
            }
            .background(Color.white.opacity(0.03))
            .overlay(Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1), alignment: .bottom)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(previewLines(), id: \.id) { line in
                    Text(line.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(line.color)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    private struct Row { let id = UUID(); let text: String; let color: Color }
    private func previewLines() -> [Row] {
        var out: [Row] = []
        for l in oldString.split(separator: "\n").prefix(3) {
            out.append(Row(text: "- \(l)", color: Color(red: 1, green: 0.61, blue: 0.58)))
        }
        for l in newString.split(separator: "\n").prefix(3) {
            out.append(Row(text: "+ \(l)", color: Color(red: 0.49, green: 0.91, blue: 0.64)))
        }
        return out
    }
}

// MARK: - shared bits

private struct BubbleBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.94))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

private struct ToolIcon: View {
    let name: String
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.06))
            .frame(width: 34, height: 34)
            .overlay(Text(iconChar).font(.system(size: 16, design: .monospaced)).foregroundColor(iconColor))
    }
    private var iconChar: String {
        switch name {
        case "Bash": return "$"
        case "Edit": return "✎"
        case "Write": return "◈"
        default: return "•"
        }
    }
    private var iconColor: Color {
        switch name {
        case "Bash": return Color(red: 0.48, green: 0.86, blue: 0.71)
        case "Edit", "Write": return Color(red: 0.42, green: 0.69, blue: 1.0)
        default: return .white
        }
    }
}

fileprivate func relativize(_ path: String, cwd: String?) -> String {
    guard let cwd = cwd, !cwd.isEmpty else { return path }
    let p = (path as NSString).standardizingPath
    let r = (cwd as NSString).standardizingPath
    if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
    if p == r { return (path as NSString).lastPathComponent }
    return path
}

fileprivate func shortenPath(_ s: String) -> String {
    let parts = s.split(separator: "/")
    if parts.count > 3 {
        return "\(parts.first ?? "")/…/\(parts.suffix(2).joined(separator: "/"))"
    }
    return s
}
