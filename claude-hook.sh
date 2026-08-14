#!/bin/bash
# claude-hook.sh - record Claude Code session state for the waybar module.
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
notification_type=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
    notification_type="$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null || true)"
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
# PID, which outlives every agent - so their state files were never pruned and
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

# The Notification payload carries a 'notification_type', and most of its values
# are not a request for you to do anything. Filtering on it is the precise fix;
# the prior-state guard below is the backstop for the ones it cannot name.
#
# This is a denylist, not an allowlist, and deliberately so: an unrecognised or
# absent type still counts as waiting, keeping the "better a spurious badge than
# a swallowed permission prompt" bias. New Claude Code releases can add types
# without this silently going quiet on a real prompt.
#
# 'idle_prompt' is the one that actually bit: it is the "Claude is waiting for
# your input" nag, fired ~60s after the session goes quiet. Backgrounding a turn
# (Ctrl-B) leaves the interactive session recorded as 'working' and fires no
# Stop hook, so the nag arrived from 'working', sailed past the prior-state
# guard, and parked the bar in amber for good with nothing to demote it. That is
# the "claude waiting when nothing is waiting" case.
case "$notification_type" in
    idle_prompt|agent_completed|auth_success|push_notification|\
    computer_use_enter|computer_use_exit|\
    elicitation_complete|elicitation_response)
        [ "$STATUS" = "waiting" ] && exit 0
        ;;
esac

# 'Notification' does not mean "blocked on a permission prompt". Claude Code
# also fires it for the "input idle for 60s" nag and for background-job
# completion / away summaries, and those arrive *after* the turn is over: Stop
# has already written 'idle', so the notification would overwrite it with
# 'waiting' and park a finished job on the bar in amber. Nothing here demotes it
# again, so every completed background job used to leave one behind.
#
# The two cases are told apart by the state they arrive from, which needs no
# extra bookkeeping: a real permission prompt happens mid-turn, when
# UserPromptSubmit/PreToolUse has just written 'working' (PreToolUse hooks run
# before the permission check, so that ordering holds). A completion or idle
# nag happens post-turn, from 'idle'. Only promote out of 'working'.
#
# With no prior state file at all, fall through and record 'waiting' - better a
# spurious badge than a swallowed permission prompt. Unclaimed pre-warmed spares
# firing stray notifications are filtered by claude-status.sh instead, on the
# absence of a job directory. Note claude-status.sh reads this file's 'waiting'
# only for the interactive session, and only while that session is not idle, so
# a stale flag here cannot reach the bar.
if [ "$STATUS" = "waiting" ] && [ -f "$state_file" ]; then
    IFS=$'\t' read -r prev_status _ < "$state_file" || prev_status=""
    if [ "$prev_status" != "working" ]; then
        exit 0
    fi
fi

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
