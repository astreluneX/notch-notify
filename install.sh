#!/bin/zsh
# NotchNotify installer.
# - Builds the Swift binary (release configuration).
# - Installs a LaunchAgent so the app starts at login and restarts on crash.
# - Prints the hook JSON snippet you need to add to ~/.claude/settings.json.
#
# Idempotent: re-running rebuilds and reloads the LaunchAgent.
set -euo pipefail

REPO_ROOT="${0:A:h}"
LABEL="com.notch-notify.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$REPO_ROOT/.build/release/NotchNotify"
BRIDGE="$REPO_ROOT/scripts/notify-bridge.sh"
PRE_HOOK="$REPO_ROOT/scripts/pre-tool-use.py"

echo "==> NotchNotify installer"
echo "    repo: $REPO_ROOT"

# --- prerequisites ------------------------------------------------------------
if ! command -v swift >/dev/null 2>&1; then
  echo "!! swift not found. Install Xcode command line tools first: xcode-select --install" >&2
  exit 1
fi

MACOS_MAJOR=$(sw_vers -productVersion | awk -F. '{print $1}')
if [[ "$MACOS_MAJOR" -lt 13 ]]; then
  echo "!! macOS 13 (Ventura) or newer is required. Detected: $(sw_vers -productVersion)" >&2
  exit 1
fi

# --- build --------------------------------------------------------------------
echo "==> Building (release) — first build fetches SwiftPM tooling and may take a minute."
(cd "$REPO_ROOT" && swift build -c release)

if [[ ! -x "$BIN" ]]; then
  echo "!! Build succeeded but binary missing at $BIN" >&2
  exit 1
fi

chmod +x "$BRIDGE" "$PRE_HOOK" 2>/dev/null || true

# --- LaunchAgent --------------------------------------------------------------
echo "==> Writing LaunchAgent to $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/notch-notify.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/notch-notify.log</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

# reload cleanly (unload first, ignore errors on fresh installs)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "==> LaunchAgent loaded. Menu bar should show 🔔 shortly."
echo

# --- hook config hint ---------------------------------------------------------
SETTINGS="$HOME/.claude/settings.json"
cat <<EOF
==> Next step: add the hooks below to $SETTINGS
    (merge with any existing hooks — don't overwrite the whole file)

{
  "hooks": {
    "Notification": [
      { "hooks": [ { "type": "command", "command": "$BRIDGE notification" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$BRIDGE stop" } ] }
    ],
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "$PRE_HOOK" } ] }
    ]
  }
}

A copy of this snippet lives at $REPO_ROOT/hooks.example.json.

Test the bubble without Claude:
  echo '{"message":"install ok"}' | $BRIDGE notification

Uninstall:
  launchctl unload $PLIST
  rm $PLIST
EOF
