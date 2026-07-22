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

# Colour follows the highest-priority state present: waiting > working > idle.
if [ "$waiting" -gt 0 ]; then
    class="waiting"
elif [ "$working" -gt 0 ]; then
    class="working"
else
    class="idle"
fi

# Build the label. When every session is in the same state, keep it simple
# ("claude working", or "claude working (3)" for several). When they differ,
# show a per-state breakdown so "1 working, 1 idle" doesn't read as "2 working".
states=0
[ "$waiting" -gt 0 ] && states=$((states+1))
[ "$working" -gt 0 ] && states=$((states+1))
[ "$idle"    -gt 0 ] && states=$((states+1))

if [ "$states" -le 1 ]; then
    [ "$waiting" -gt 0 ] && word="waiting"
    [ "$working" -gt 0 ] && word="working"
    [ "$idle"    -gt 0 ] && word="idle"
    text="claude $word"
    [ "$total" -gt 1 ] && text="$text ($total)"
else
    parts=""
    [ "$waiting" -gt 0 ] && parts="$parts  $waiting waiting"
    [ "$working" -gt 0 ] && parts="$parts  $working working"
    [ "$idle"    -gt 0 ] && parts="$parts  $idle idle"
    text="claude${parts}"
fi

# Trim trailing newline from tooltip.
tooltip="${tooltip%\\n}"

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$class" "$tooltip"
exit 0
