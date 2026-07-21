#!/bin/bash
# claude-status.sh — waybar custom module for Claude Code session status.
#
# Aggregates the per-session state files written by claude-hook.sh and emits
# one line of JSON ({"text","class","tooltip"}) for waybar to render.
#
# Priority when several sessions are active:  waiting > working > idle.
# Stale files (crashed sessions that never fired an end hook) are pruned.
set -euo pipefail

STATE_DIR="${CLAUDE_WAYBAR_STATE_DIR:-$HOME/.cache/claude-waybar/sessions}"
STALE_SECS="${CLAUDE_WAYBAR_STALE_SECS:-86400}"   # drop sessions older than 24h

mkdir -p "$STATE_DIR"

now="$(date +%s)"
waiting=0 working=0 idle=0
tooltip=""

shopt -s nullglob
for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r status ts cwd < "$f" || continue
    [ -z "${ts:-}" ] && ts=0
    if [ $(( now - ts )) -gt "$STALE_SECS" ]; then
        rm -f "$f"
        continue
    fi
    case "$status" in
        waiting) waiting=$((waiting+1)) ;;
        working) working=$((working+1)) ;;
        *)       idle=$((idle+1)) ;;
    esac
    label="${cwd##*/}"
    [ -z "$label" ] && label="?"
    tooltip="${tooltip}${status}\t${label}\n"
done

total=$((waiting+working+idle))

if [ "$total" -eq 0 ]; then
    # No active Claude sessions — emit empty text so the module collapses.
    printf '{"text":"","class":"none","tooltip":false}\n'
    exit 0
fi

if [ "$waiting" -gt 0 ]; then
    class="waiting"; word="waiting"
elif [ "$working" -gt 0 ]; then
    class="working"; word="working"
else
    class="idle"; word="idle"
fi

text="claude $word"
[ "$total" -gt 1 ] && text="$text ($total)"

# Trim trailing newline from tooltip.
tooltip="${tooltip%\\n}"

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$class" "$tooltip"
exit 0
