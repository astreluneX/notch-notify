#!/usr/bin/env python3
"""Blocking PreToolUse hook for NotchNotify.

Reads Claude Code hook JSON from stdin, forwards a request to the notch app,
waits up to 30s for the user's decision, and emits the corresponding
permission JSON back to Claude Code on stdout.

Fail-open: any error / missing socket / timeout returns an empty JSON so Claude
falls back to its built-in permission prompt.
"""
from __future__ import annotations
import json
import os
import socket
import sys
import time
import uuid

SOCK_PATH = os.path.expanduser("~/Library/Application Support/NotchNotify/notch.sock")
TIMEOUT_SECONDS = 30.5


def _read_hook_input() -> dict:
    try:
        raw = sys.stdin.read()
    except Exception:
        return {}
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def _detect_caller_bundle() -> str | None:
    """Prefer $__CFBundleIdentifier; fall back to walking the parent chain."""
    bundle = os.environ.get("__CFBundleIdentifier")
    if bundle:
        return bundle
    try:
        import subprocess
        pid = os.getppid()
        for _ in range(12):
            if pid in (0, 1):
                break
            out = subprocess.check_output(["ps", "-o", "command=,ppid=", "-p", str(pid)],
                                          text=True, stderr=subprocess.DEVNULL)
            line = out.strip().splitlines()[0] if out.strip() else ""
            parts = line.rsplit(None, 1)
            if len(parts) == 2:
                cmd, ppid_s = parts[0], parts[1]
                if ".app/" in cmd:
                    bundle_root = cmd.split(".app/", 1)[0] + ".app"
                    plist = os.path.join(bundle_root, "Contents", "Info.plist")
                    if os.path.isfile(plist):
                        r = subprocess.run(
                            ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist],
                            capture_output=True, text=True)
                        if r.returncode == 0:
                            return r.stdout.strip() or None
                try:
                    pid = int(ppid_s)
                except ValueError:
                    break
            else:
                break
    except Exception:
        pass
    return None


def _request(payload: dict) -> dict | None:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(TIMEOUT_SECONDS)
        s.connect(SOCK_PATH)
        s.sendall((json.dumps(payload) + "\n").encode("utf-8"))

        # Read until newline / socket close
        buf = b""
        deadline = time.time() + TIMEOUT_SECONDS
        while time.time() < deadline:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            if b"\n" in buf:
                break
        s.close()
        if not buf:
            return None
        return json.loads(buf.decode("utf-8").strip())
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
        return None
    except Exception:
        return None


def _emit(decision_output: dict) -> None:
    """Write the hook decision JSON to stdout. Claude reads this."""
    try:
        json.dump(decision_output, sys.stdout)
    except Exception:
        pass
    sys.stdout.write("\n")
    sys.stdout.flush()


def _passthrough() -> None:
    """No decision — let Claude's built-in permission logic run."""
    sys.stdout.write("{}\n")
    sys.stdout.flush()
    sys.exit(0)


MUTATING_TOOLS = {"Bash", "Edit", "Write", "NotebookEdit", "MultiEdit"}
READONLY_TOOLS = {"Read", "Grep", "Glob", "WebFetch", "WebSearch"}


def _readonly_path_outside_cwd(tool_name: str, tool_input: dict, cwd: str | None) -> bool:
    """Return True when a read-only tool references a path clearly outside cwd.

    Reads/greps/globs inside cwd never trigger the bubble — otherwise every file
    read fires a notification and the UX becomes unusable. Reads outside cwd
    (root, home, other projects) still gate through the bubble so 'Session'
    can widen the scope for the remainder of the conversation.
    """
    if not cwd:
        return False
    try:
        cwd_abs = os.path.realpath(cwd)
    except OSError:
        return False

    def _outside(candidate: str) -> bool:
        if not candidate:
            return False
        try:
            resolved = os.path.realpath(os.path.expanduser(candidate))
        except OSError:
            return False
        if not os.path.isabs(resolved):
            return False
        return not (resolved == cwd_abs or resolved.startswith(cwd_abs + os.sep))

    if tool_name == "Read":
        return _outside(tool_input.get("file_path") or "")
    if tool_name == "Grep":
        return _outside(tool_input.get("path") or "")
    if tool_name == "Glob":
        return _outside(tool_input.get("path") or "")
    # WebFetch / WebSearch never target the filesystem — always gate so users can Session-allow them.
    if tool_name in {"WebFetch", "WebSearch"}:
        return True
    return False


def main() -> None:
    hook = _read_hook_input()
    tool_name = hook.get("tool_name") or ""
    tool_input = hook.get("tool_input") or {}
    cwd = hook.get("cwd") or tool_input.get("cwd")
    session_id = hook.get("session_id")

    if tool_name in MUTATING_TOOLS:
        pass  # always gate mutating tools
    elif tool_name in READONLY_TOOLS:
        if not _readonly_path_outside_cwd(tool_name, tool_input, cwd):
            return _passthrough()
    else:
        return _passthrough()

    if not os.path.exists(SOCK_PATH):
        return _passthrough()

    payload = {
        "type": "request",
        "requestId": str(uuid.uuid4()),
        "tool": tool_name,
        "toolInput": tool_input,
        "cwd": cwd,
        "sessionId": session_id,
        "sourceApp": _detect_caller_bundle(),
        "timestamp": time.time(),
    }
    reply = _request(payload)
    if not reply:
        return _passthrough()

    decision = reply.get("decision", "")
    if decision in ("allowOnce", "allowSession", "allowAlways"):
        _emit({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "NotchNotify: user approved via bubble"
            }
        })
    elif decision == "deny":
        _emit({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "NotchNotify: user denied via bubble"
            }
        })
    else:
        # passthrough / timeout / unknown → user will handle in terminal;
        # Claude runs its built-in permission prompt as if the hook wasn't there
        _passthrough()


if __name__ == "__main__":
    main()
