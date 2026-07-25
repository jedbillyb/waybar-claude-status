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
# A 'working' session with no hook activity for this long is shown as idle.
# Claude Code fires no hook on user interrupt (Esc), so 'working' can otherwise
# get stuck; PreToolUse/PostToolUse refresh the timestamp during real work.
WORK_TIMEOUT="${CLAUDE_WAYBAR_WORK_TIMEOUT:-90}"
# Background jobs and Task/agent sessions are separate sessions with their own
# state files, so a single terminal running agents legitimately reports several.
# 'count' includes them (a waiting background job is worth noticing); 'hide'
# keeps the module reporting only the session you are typing in.
AGENTS="${CLAUDE_WAYBAR_AGENTS:-count}"
# The interactive session is the one you are looking at, so an idle or waiting
# terminal does not need a badge — only count it while it is actually working.
# 'always' restores counting it in every state (useful if you keep sessions on
# other workspaces and want their permission prompts on the bar).
MAIN="${CLAUDE_WAYBAR_MAIN:-working}"

mkdir -p "$STATE_DIR"

now="$(date +%s)"
waiting=0 working=0 idle=0
# Agent/background sessions are counted separately from the interactive ones, so
# the label can read "claude idle +3" instead of folding your own terminal into
# the agent count and claiming 4 sessions when you started 3 agents.
a_waiting=0 a_working=0 a_idle=0
tooltip=""
tooltip_agents=""

shopt -s nullglob
for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    # 'kind' (main|agent) is absent in files written by older hook versions;
    # treat those as main sessions.
    IFS=$'\t' read -r status ts cwd pid kind < "$f" || continue
    [ -z "${kind:-}" ] && kind="main"
    [ -z "${ts:-}" ] && ts=0
    # Prune orphans: if the owning claude PID is recorded but no longer alive,
    # the session died without firing its 'end' hook (crash/kill/close). This
    # is the primary cleanup; the timeouts below are backstops for older files
    # written before PIDs were tracked, or PID reuse edge cases.
    if [ -n "${pid:-}" ] && ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$f"
        continue
    fi
    if [ $(( now - ts )) -gt "$STALE_SECS" ]; then
        rm -f "$f"
        continue
    fi
    # No interrupt hook exists, so demote a stale 'working' session to idle.
    if [ "$status" = "working" ] && [ $(( now - ts )) -gt "$WORK_TIMEOUT" ]; then
        status="idle"
    fi
    # Skip after pruning, never before, so hidden agent sessions still get
    # their stale files cleaned up.
    if [ "$AGENTS" = "hide" ] && [ "$kind" = "agent" ]; then
        continue
    fi
    if [ "$kind" = "agent" ]; then
        case "$status" in
            waiting) a_waiting=$((a_waiting+1)) ;;
            working) a_working=$((a_working+1)) ;;
            *)       a_idle=$((a_idle+1)) ;;
        esac
    elif [ "$MAIN" = "always" ] || [ "$status" = "working" ]; then
        case "$status" in
            waiting) waiting=$((waiting+1)) ;;
            working) working=$((working+1)) ;;
            *)       idle=$((idle+1)) ;;
        esac
    fi
    label="${cwd##*/}"
    [ -z "$label" ] && label="?"
    # Mark background/agent sessions so a count above 1 is self-explanatory
    # when only one terminal is open, and list them after the interactive ones.
    if [ "$kind" = "agent" ]; then
        tooltip_agents="${tooltip_agents}${status}\t${label} (agent)\n"
    else
        tooltip="${tooltip}${status}\t${label}\n"
    fi
done

tooltip="${tooltip}${tooltip_agents}"

agents=$((a_waiting+a_working+a_idle))

# When no interactive session is registered (it may not have fired a hook yet)
# the agents stand in for it, so the label is built from their counts instead of
# reporting nothing. Otherwise agents only ever contribute the "+N" suffix.
if [ $((waiting+working+idle)) -eq 0 ] && [ "$agents" -gt 0 ]; then
    waiting=$a_waiting working=$a_working idle=$a_idle
    a_waiting=0 a_working=0 a_idle=0
    agents=0
fi

total=$((waiting+working+idle))

if [ "$total" -eq 0 ]; then
    # No active Claude sessions — emit empty text so the module collapses.
    printf '{"text":"","class":"none","tooltip":false}\n'
    exit 0
fi

# Per-state colours (override to match your style.css). Used for the Pango
# markup in the mixed-state label so each count is coloured by its own state.
COLOR_WAITING="${CLAUDE_WAYBAR_COLOR_WAITING:-#e0af68}"
COLOR_WORKING="${CLAUDE_WAYBAR_COLOR_WORKING:-#9ece6a}"
COLOR_IDLE="${CLAUDE_WAYBAR_COLOR_IDLE:-#7f849c}"

# Colour follows the highest-priority state present: waiting > working > idle.
# Agents count towards it: an agent stuck on a permission prompt is the whole
# reason to glance at the bar.
if [ $((waiting+a_waiting)) -gt 0 ]; then
    class="waiting"
elif [ $((working+a_working)) -gt 0 ]; then
    class="working"
else
    class="idle"
fi

# Build the label. When every session is in the same state, keep it simple
# ("claude working", or "claude working (3)" for several) and let the CSS class
# colour it. When they differ, show a per-state breakdown with each count
# coloured by its own state via Pango markup, so "1 working, 1 idle" doesn't
# read (or look) like "2 working".
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
    class="mixed"   # neutral base colour; the spans below colour each segment
    parts=""
    [ "$waiting" -gt 0 ] && parts="$parts  <span foreground='$COLOR_WAITING'>$waiting waiting</span>"
    [ "$working" -gt 0 ] && parts="$parts  <span foreground='$COLOR_WORKING'>$working working</span>"
    [ "$idle"    -gt 0 ] && parts="$parts  <span foreground='$COLOR_IDLE'>$idle idle</span>"
    text="claude${parts}"
fi

# Agents ride along as a "+N" suffix, coloured by their own highest-priority
# state, so the number always matches the number of agents you started and the
# main label keeps meaning "the session I am typing in".
if [ "$agents" -gt 0 ]; then
    if [ "$a_waiting" -gt 0 ]; then
        a_color="$COLOR_WAITING"
    elif [ "$a_working" -gt 0 ]; then
        a_color="$COLOR_WORKING"
    else
        a_color="$COLOR_IDLE"
    fi
    text="$text <span foreground='$a_color'>+$agents</span>"
fi

# Trim trailing newline from tooltip.
tooltip="${tooltip%\\n}"

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$class" "$tooltip"
exit 0
