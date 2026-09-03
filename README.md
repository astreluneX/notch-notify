# NotchNotify

A tiny macOS helper that pops a bubble under your MacBook notch when Claude Code
needs your attention — permission requests, task completion, and (optionally)
in-line approval of tool calls. Never miss a `permission` prompt again just
because you switched windows.

<sub>Requires macOS 13+ · Swift toolchain · [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)</sub>

## What it does

- **Notification bubble** — Claude asks for permission → an orange bubble slides
  down under the notch with the question. Click it to bring your terminal
  forward.
- **Stop bubble** — Claude finishes a task → a green bubble tells you it's done.
- **In-bubble approvals (optional)** — for `Bash` / `Edit` / `Write` and
  reads outside your project root, the bubble also lets you Allow (once /
  session / always) or Deny, without switching windows. Dangerous commands
  (`rm -rf`, `sudo`, force-push, sensitive files) light up red.

Falls back to a plain `osascript` notification if the app isn't running, so
Claude Code never blocks.

## Install

```bash
git clone https://github.com/astreluneX/notch-notify.git ~/notch-notify
cd ~/notch-notify
./install.sh
```

The installer builds the app, installs a LaunchAgent so it starts at login,
and prints the hook snippet you need to add to `~/.claude/settings.json`.

### Wire up the hooks

Merge the JSON below (also saved as `hooks.example.json`) into your existing
`~/.claude/settings.json`. If the file doesn't exist yet, this whole snippet
is a valid starter file.

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [ { "type": "command", "command": "$HOME/notch-notify/scripts/notify-bridge.sh notification" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$HOME/notch-notify/scripts/notify-bridge.sh stop" } ] }
    ],
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "$HOME/notch-notify/scripts/pre-tool-use.py" } ] }
    ]
  }
}
```

If you don't want in-bubble tool approvals, omit the `PreToolUse` block — the
notification and stop bubbles work standalone.

### Test it

```bash
echo '{"message":"hello notch"}' | ~/notch-notify/scripts/notify-bridge.sh notification
```

A bubble should appear under the notch. You can also click the menu-bar 🔔 for
built-in test triggers.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.notch-notify.app.plist
rm ~/Library/LaunchAgents/com.notch-notify.app.plist
```

Then delete the notch-notify hook entries from `~/.claude/settings.json`.

## How it works

```
Claude Code hook
    ↓
scripts/notify-bridge.sh   (Notification / Stop — fire-and-forget)
scripts/pre-tool-use.py    (PreToolUse — blocks up to 30s waiting for user)
    ↓ Unix domain socket
~/Library/Application Support/NotchNotify/notch.sock
    ↓
NotchNotify (menu bar + floating panel)
```

The Swift app is intentionally small: a menu-bar `NSStatusItem`, a borderless
floating `NSPanel` pinned under the notch, and a `SocketServer` that reads
newline-delimited JSON events. `RiskAnalyzer` classifies tool calls into
`safe` / `action` / `danger` for the UI.

## Project layout

```
notch-notify/
├── Package.swift
├── install.sh
├── hooks.example.json
├── LICENSE
├── Sources/NotchNotify/
│   ├── main.swift
│   ├── AppDelegate.swift        # menu bar + LaunchAgent-ready lifecycle
│   ├── NotchPanel.swift         # NSPanel pinned under the notch
│   ├── BubbleView.swift         # SwiftUI bubble
│   ├── NotchEvent.swift         # event model + in-memory store
│   ├── SocketServer.swift       # accepts hook events
│   ├── RiskAnalyzer.swift       # safe / action / danger heuristics
│   ├── PermissionStore.swift    # session/always allow rules
│   ├── PendingRequest.swift     # in-flight approval requests
│   └── FeatureToggle.swift      # menu-bar on/off switch
└── scripts/
    ├── notify-bridge.sh         # Notification / Stop bridge (non-blocking)
    └── pre-tool-use.py          # PreToolUse bridge (blocking, 30s timeout)
```

## Rebuilding

```bash
cd ~/notch-notify
swift build -c release
launchctl kickstart -k gui/$(id -u)/com.notch-notify.app
```

Or just re-run `./install.sh` — it's idempotent.

## Compatibility notes

- If the socket is missing or the app is down, `notify-bridge.sh` degrades to
  `osascript display notification` and exits 0. Claude Code never blocks.
- `pre-tool-use.py` fails open on any error — Claude falls back to its
  built-in permission prompt if the bubble can't respond within 30s.
- Bubble stays 12 seconds by default. Click anywhere to bring your terminal
  forward (Terminal / iTerm2 / Ghostty / Alacritty / WezTerm / Warp).
- Existing hooks in `~/.claude/settings.json` are respected — Claude Code
  runs all registered hooks for an event, so notch-notify coexists with
  whatever else you have wired up.

## License

MIT — see [LICENSE](LICENSE).
