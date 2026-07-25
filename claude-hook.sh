#!/bin/bash
# claude-hook.sh — record Claude Code session state for the waybar module.
#
# Wired into Claude Code hooks. Reads the hook JSON on stdin, derives a status
# for the session, writes it to a per-session state file, then pokes waybar so
# the module refreshes instantly instead of waiting for its poll interval.
#
# Usage (from settings.json hooks):  claude-hook.sh <status>
#   where <status> is one of: working | waiting | idle | end
#
set -euo pipefail

STATUS="${1:-idle}"
STATE_DIR="${CLAUDE_WAYBAR_STATE_DIR:-$HOME/.cache/claude-waybar/sessions}"
SIGNAL="${CLAUDE_WAYBAR_SIGNAL:-10}"   # waybar SIGRTMIN+N, must match config

mkdir -p "$STATE_DIR"

# Hook payload arrives as JSON on stdin. Pull out the fields we care about.
# Fall back gracefully if jq is missing or stdin is empty.
payload="$(cat 2>/dev/null || true)"
session_id=""
cwd=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "$session_id" ] && session_id="unknown-$$"

state_file="$STATE_DIR/$session_id"

# Find the owning claude process by walking up the ancestry. Hooks are run via
# a short-lived shell (e.g. `sh -c`), so $PPID itself is gone by the next poll;
# we want the long-lived claude PID. The status module uses it to prune orphaned
# files when a session dies without firing the SessionEnd 'end' hook (crash,
# killed terminal, Esc-interrupt). Empty if not found (older layouts).
#
# The interactive session's process is named `claude`, but background jobs and
# agent sessions run as `claude.exe` nested underneath it. Matching only
# `claude` walked straight past those and recorded the top-level interactive
# PID, which outlives every agent — so their state files were never pruned and
# the module accumulated phantom sessions. Match both names, and stop at the
# nearest claude ancestor: that is the session which actually owns this hook.
find_claude_pid() {
    local p="$PPID" comm
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        comm="$(cat "/proc/$p/comm" 2>/dev/null || true)"
        if [ "$comm" = "claude" ] || [ "$comm" = "claude.exe" ]; then
            printf '%s' "$p"; return
        fi
        p="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)"
    done
}

# Classify the session so the tooltip can tell a background or agent session
# apart from the terminal you are typing in. Only spawned sessions carry
# --session-id (or a --bg-* flag); the interactive one is a bare `claude`.
session_kind() {
    local pid="$1" args
    [ -z "$pid" ] && { printf 'main'; return; }
    args="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$args" in
        *--session-id*|*--bg-*|*--agent\ *) printf 'agent' ;;
        *)                                  printf 'main' ;;
    esac
}

if [ "$STATUS" = "end" ]; then
    rm -f "$state_file"
else
    claude_pid="$(find_claude_pid)"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$STATUS" "$(date +%s)" "$cwd" "$claude_pid" "$(session_kind "$claude_pid")" \
        > "$state_file"
fi

# Nudge waybar to re-run the module now (SIGRTMIN+SIGNAL).
pkill -RTMIN+"$SIGNAL" waybar 2>/dev/null || true

exit 0
