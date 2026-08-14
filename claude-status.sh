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
#
# 'active' (default) counts only agents that are working or waiting. Claude Code
# keeps pre-warmed `claude bg-spare` workers around for background jobs; each
# fires SessionStart and then sits at 'idle' until it is claimed, so counting
# idle agents put phantom sessions on the bar that were never started. A
# finished agent
# whose process lingers looks the same. Either way an idle agent is nothing to
# glance at, so it stays out of the badge and remains listed in the tooltip.
# 'count' includes idle agents too; 'hide' keeps the module reporting only the
# session you are typing in.
AGENTS="${CLAUDE_WAYBAR_AGENTS:-active}"
# The interactive session is the one you are looking at, so a merely idle
# terminal does not need a badge. 'waiting' is always counted regardless of
# this setting though — a pending permission prompt or AskUserQuestion is
# exactly the case the badge exists for, especially when you've alt-tabbed
# away from it. 'always' additionally counts idle (useful if you keep sessions
# on other workspaces).
MAIN="${CLAUDE_WAYBAR_MAIN:-working}"
# Claude Code writes a transcript per real session under this directory. A
# pre-warmed `claude bg-spare` worker fires SessionStart (so it gets a state
# file) but never gets a transcript until it is claimed and given real work, so
# the presence of a transcript is what separates an agent you actually started
# from a phantom. Set to empty to disable the check.
PROJECTS_DIR="${CLAUDE_WAYBAR_PROJECTS_DIR:-$HOME/.claude/projects}"
# Background jobs keep their own state under this directory, one dir per job
# holding a state.json with the job's sessionId and state. A job that ends its
# turn asking the user something goes to state 'blocked', but Claude Code fires
# no hook for that: the turn ended, so Stop has already written 'idle' and no
# Notification follows (that only covers mid-turn permission prompts). The job
# therefore sat on the bar in grey while it was in fact the one thing you needed
# to look at. Reading the job state directly is what catches it. Set to empty to
# disable.
JOBS_DIR="${CLAUDE_WAYBAR_JOBS_DIR:-$HOME/.claude/jobs}"

mkdir -p "$STATE_DIR"

# True when this session has a transcript on disk, i.e. it is a session rather
# than an unclaimed spare. Errs towards "real": if the project directory for
# this cwd does not exist at all (custom CLAUDE_CONFIG_DIR, transcripts
# disabled) the check is skipped rather than hiding every agent.
has_transcript() {
    local id="$1" cwd="$2" dir
    [ -z "$PROJECTS_DIR" ] && return 0
    dir="$PROJECTS_DIR/${cwd//[^a-zA-Z0-9]/-}"
    [ -d "$dir" ] || return 0
    [ -f "$dir/$id.jsonl" ]
}

now="$(date +%s)"
waiting=0 working=0 idle=0
# Agent/background sessions are counted separately from the interactive ones, so
# the label can read "claude idle +3" instead of folding your own terminal into
# the agent count and claiming 4 sessions when you started 3 agents.
a_waiting=0 a_working=0 a_idle=0
tooltip=""
tooltip_agents=""

shopt -s nullglob

# Session ids of background jobs currently blocked on the user, space-delimited
# and space-padded so a plain glob match can't hit a partial id. jq is already a
# dependency of the hook; without it the check degrades to the old behaviour
# rather than failing.
blocked_ids=" "
if [ -n "$JOBS_DIR" ] && command -v jq >/dev/null 2>&1; then
    job_states=("$JOBS_DIR"/*/state.json)
    if [ "${#job_states[@]}" -gt 0 ]; then
        blocked_ids=" $(jq -r 'select(.state == "blocked") | .sessionId // empty' \
            "${job_states[@]}" 2>/dev/null | tr '\n' ' ')"
    fi
fi

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
    # A job blocked on the user outranks whatever the hooks last recorded, and
    # is applied after the timeout above so it can't be demoted back to idle.
    case "$blocked_ids" in
        *" ${f##*/} "*) status="waiting" ;;
    esac
    # Skip after pruning, never before, so hidden agent sessions still get
    # their stale files cleaned up.
    if [ "$AGENTS" = "hide" ] && [ "$kind" = "agent" ]; then
        continue
    fi
    # Drop pre-warmed spares. They fire SessionStart, so they own a state file
    # and a live PID, but never get a transcript until they are claimed. Left in
    # they show up as agents that were never started — and one stuck at
    # 'waiting' turns the whole badge amber as if a permission prompt were
    # pending. Only agents are checked: the interactive session is never a
    # spare, and hiding it mid-startup would be worse than showing it early.
    if [ "$kind" = "agent" ] && ! has_transcript "${f##*/}" "$cwd"; then
        continue
    fi
    if [ "$kind" = "agent" ]; then
        case "$status" in
            waiting) a_waiting=$((a_waiting+1)) ;;
            working) a_working=$((a_working+1)) ;;
            # Idle agents only reach the badge under AGENTS=count; see above.
            *)       if [ "$AGENTS" = "count" ]; then a_idle=$((a_idle+1)); fi ;;
        esac
    elif [ "$MAIN" = "always" ] || [ "$status" = "working" ] || [ "$status" = "waiting" ]; then
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

total=$((waiting+working+idle))

if [ $((total+agents)) -eq 0 ]; then
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

if [ "$total" -eq 0 ]; then
    # Nothing to say about the interactive session: it is idle or waiting under
    # MAIN=working, or it has not registered a state file yet. The agent suffix
    # below carries the label on its own — previously the agent counts were
    # copied into the main slot here, which dropped the "+N" entirely and read
    # as though the agents were terminals you were sitting in front of.
    text="claude"
elif [ "$states" -le 1 ]; then
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
#
# An agent that needs input says so in words. Colour alone did not carry it:
# "3 agents running" and "one of them is blocked on you" both rendered as
# "claude +3", told apart only by the hue of a two-character span, and when the
# interactive session had a word of its own the label read "claude working" while
# something sat waiting on an answer. Since noticing that is the entire job of
# this module, the suffix spells it out. Working and idle agents are unchanged —
# the bare "+N" is right for them.
if [ "$agents" -gt 0 ]; then
    suffix="+$agents"
    if [ "$a_waiting" -gt 0 ]; then
        a_color="$COLOR_WAITING"
        if [ "$a_waiting" -eq "$agents" ]; then
            suffix="+$agents waiting"
        else
            suffix="+$agents ($a_waiting waiting)"
        fi
    elif [ "$a_working" -gt 0 ]; then
        a_color="$COLOR_WORKING"
    else
        a_color="$COLOR_IDLE"
    fi
    text="$text <span foreground='$a_color'>$suffix</span>"
fi

# Trim trailing newline from tooltip.
tooltip="${tooltip%\\n}"

printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text" "$class" "$tooltip"
exit 0
