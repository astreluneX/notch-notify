#!/bin/zsh
# NotchNotify bridge for Claude Code hooks.
# Reads hook JSON from stdin, forwards a compact payload (with caller bundle id) to the notch app.
# Never blocks / never errors: Claude Code should keep running even if the notch app is down.

set -u
SOCK="$HOME/Library/Application Support/NotchNotify/notch.sock"
KIND="${1:-notification}"

# ---------- caller-app detection ----------
# Walk up the process tree until we find a process whose executable lives inside an .app bundle.
# Return its CFBundleIdentifier from Info.plist. Empty string on failure.
find_bundle_id() {
  local pid=${1:-$PPID}
  local hops=0
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && "$hops" -lt 12 ]]; do
    local exe
    exe=$(ps -o command= -p "$pid" 2>/dev/null | awk '{print $1}')
    if [[ "$exe" == *.app/* ]]; then
      local bundle="${exe%%.app/*}.app"
      if [[ -f "$bundle/Contents/Info.plist" ]]; then
        /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$bundle/Contents/Info.plist" 2>/dev/null && return
      fi
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  return 1
}

# Prefer $__CFBundleIdentifier (set by Launch Services when the calling app opened this process tree).
CALLER_BUNDLE="${__CFBundleIdentifier:-}"
if [[ -z "$CALLER_BUNDLE" ]]; then
  CALLER_BUNDLE="$(find_bundle_id 2>/dev/null || true)"
fi

# ---------- hook payload extraction ----------
INPUT="$(cat 2>/dev/null || true)"

if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
  MESSAGE=$(printf '%s' "$INPUT" | jq -r '.message // .prompt // .stop_reason // .tool_name // empty' 2>/dev/null)
  CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
else
  MESSAGE=""
  CWD=""
  SESSION=""
fi

case "$KIND" in
  notification)
    TITLE="Claude 需要你回答"
    BODY="${MESSAGE:-Claude Code 有待处理的提示}"
    ;;
  stop)
    TITLE="Claude 已完成"
    BODY="${MESSAGE:-任务结束，回到会话确认}"
    ;;
  prompt-submit)
    TITLE="Claude 接收到指令"
    BODY="${MESSAGE:-已提交给 Claude Code}"
    ;;
  *)
    TITLE="Claude"
    BODY="${MESSAGE:-事件: $KIND}"
    ;;
esac

PAYLOAD=$(/usr/bin/python3 - "$KIND" "$TITLE" "$BODY" "$CWD" "$SESSION" "$CALLER_BUNDLE" <<'PY'
import json, sys, time
kind, title, body, cwd, session, caller = sys.argv[1:7]
print(json.dumps({
    "kind": kind,
    "title": title,
    "body": (body[:220] + "…") if len(body) > 221 else body,
    "source": "claude-code",
    "sourceApp": caller or None,
    "timestamp": time.time(),
    "cwd": cwd,
    "session": session,
}))
PY
)

if [[ ! -S "$SOCK" ]]; then
  /usr/bin/osascript -e "display notification \"$BODY\" with title \"$TITLE\"" >/dev/null 2>&1 || true
  exit 0
fi

/usr/bin/python3 - "$SOCK" "$PAYLOAD" <<'PY' >/dev/null 2>&1 || true
import socket, sys
sock_path, payload = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
try:
    s.connect(sock_path)
    s.sendall((payload + "\n").encode("utf-8"))
finally:
    s.close()
PY

exit 0
