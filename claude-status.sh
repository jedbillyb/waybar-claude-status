#!/bin/bash
# claude-status.sh — waybar custom module for Claude Code session status.
#
# Emits one line of JSON ({"text","class","tooltip"}) for waybar to render.
#
# Priority when several sessions are active:  waiting > working > idle.
#
# This reads Claude Code's own live state files rather than reconstructing state
# from hook events. Hooks are events, and several transitions fire no event at
# all: backgrounding a turn fires no Stop, a job going blocked fires nothing, an
# Esc interrupt fires nothing. A state machine driven only by those events gets
# stuck, and every correction for one stuck case (activity timeouts, orphan
# pruning, notification filtering) was another guess layered on the last.
#
# Claude Code publishes what it is actually doing:
#
#   ~/.claude/sessions/<pid>.json      kind: interactive|bg, status: busy|idle,
#                                      sessionId, cwd, name — rewritten live
#   ~/.claude/jobs/<short-id>/state.json   state: working|blocked|done|failed
#                                      — 'blocked' is the real "needs input"
#
# So those are the source of truth, and the hook state file is consulted for
# exactly one thing it alone knows: a permission prompt interrupting a turn in
# the interactive session. See claude-hook.sh.
set -euo pipefail

# Written by claude-hook.sh. Only the interactive session's entry is read; the
# rest is kept pruned so nothing accumulates.
STATE_DIR="${CLAUDE_WAYBAR_STATE_DIR:-$HOME/.cache/claude-waybar/sessions}"
STALE_SECS="${CLAUDE_WAYBAR_STALE_SECS:-86400}"   # drop hook files older than 24h
# Claude Code's live per-process session state, one <pid>.json per session. This
# is the enumeration: a session with no file here is not running.
SESSIONS_DIR="${CLAUDE_WAYBAR_SESSIONS_DIR:-$HOME/.claude/sessions}"
# Claude Code's background-job state, one directory per job named after the first
# 8 characters of the session id.
JOBS_DIR="${CLAUDE_WAYBAR_JOBS_DIR:-$HOME/.claude/jobs}"

# Background jobs and Task/agent sessions are separate sessions with their own
# state, so a single terminal running agents legitimately reports several.
#
# 'active' (default) counts only agents that are working or waiting. An idle
# agent is nothing to glance at, so it stays out of the badge and remains listed
# in the tooltip. 'count' includes idle agents too; 'hide' keeps the module
# reporting only the session you are typing in.
AGENTS="${CLAUDE_WAYBAR_AGENTS:-active}"
# The interactive session is the one you are looking at, so a merely idle
# terminal does not need a badge. 'waiting' is always counted regardless — a
# pending permission prompt is exactly the case the badge exists for, especially
# when you've alt-tabbed away. 'always' additionally counts idle.
MAIN="${CLAUDE_WAYBAR_MAIN:-working}"

mkdir -p "$STATE_DIR"

now="$(date +%s)"

shopt -s nullglob

# ---------------------------------------------------------------------------
# Read Claude Code's state. Two jq invocations total, whatever the session count.
# ---------------------------------------------------------------------------

# sessionId -> job state, for background jobs. A bg session with no entry here is
# an unclaimed pre-warmed `claude bg-spare` worker: it has a session file and a
# live pid but was never given work, and counting those put phantom agents on the
# bar. Having a job directory is what separates an agent you actually started.
declare -A job_state=()
job_files=("$JOBS_DIR"/*/state.json)
if [ -n "$JOBS_DIR" ] && [ "${#job_files[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r sid st; do
        [ -n "$sid" ] && job_state["$sid"]="$st"
    done < <(jq -r '[(.sessionId // ""), (.state // "")] | @tsv' \
                "${job_files[@]}" 2>/dev/null || true)
fi

# The interactive session's hook-recorded status, keyed by session id. Only
# 'waiting' is meaningful: it means a permission prompt interrupted the turn,
# which the sessions file does not distinguish from ordinary work.
declare -A hook_status=()
for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r hs hts _ hpid _ < "$f" || continue
    # The hook dir is ours, so prune it here. A dead pid means the session went
    # away without firing SessionEnd (crash, killed terminal); the age check is a
    # backstop for files written before pids were recorded.
    if { [ -n "${hpid:-}" ] && ! kill -0 "$hpid" 2>/dev/null; } ||
       [ $(( now - ${hts:-0} )) -gt "$STALE_SECS" ]; then
        rm -f "$f"
        continue
    fi
    hook_status["${f##*/}"]="$hs"
done

# ---------------------------------------------------------------------------
# Classify every live session.
# ---------------------------------------------------------------------------

waiting=0 working=0 idle=0          # the interactive session
a_waiting=0 a_working=0 a_idle=0    # background/agent sessions
tooltip="" tooltip_agents=""

session_files=("$SESSIONS_DIR"/*.json)
if [ "${#session_files[@]}" -gt 0 ]; then
while IFS=$'\t' read -r pid kind cc_status sid cwd name; do
    [ -n "$pid" ] || continue
    # Claude Code owns these files and does not always remove them promptly, so
    # liveness is decided by the process, not the file.
    kill -0 "$pid" 2>/dev/null || continue

    # Job directories are named after the short id, but their state.json carries
    # the full sessionId, which is what the map is keyed by.
    short="${sid:0:8}"
    jstate="${job_state[$sid]-}"

    if [ "$kind" = "bg" ]; then
        # No job directory means an unclaimed spare, not an agent you started.
        [ -n "$jstate" ] || continue

        # 'blocked' is the job waiting on you. It is authoritative except when
        # the session is busy: answering a blocked job puts it straight back to
        # work, but state.json can lag a minute or more behind (your answer shows
        # up as the job's 'detail' while 'state' trails), which reported jobs as
        # waiting well after they had resumed.
        if [ "$jstate" = "blocked" ] && [ "$cc_status" != "busy" ]; then
            status="waiting"
        elif [ "$cc_status" = "busy" ]; then
            status="working"
        else
            status="idle"
        fi
    else
        # The interactive session. A permission prompt interrupts a live turn, so
        # the session reads busy and only the hook knows it is actually blocked;
        # once the turn is over (idle) any lingering hook 'waiting' is stale.
        if [ "${hook_status[$sid]-}" = "waiting" ] && [ "$cc_status" != "idle" ]; then
            status="waiting"
        elif [ "$cc_status" = "busy" ]; then
            status="working"
        else
            status="idle"
        fi
    fi

    if [ "$kind" = "bg" ]; then
        [ "$AGENTS" = "hide" ] && continue
        case "$status" in
            waiting) a_waiting=$((a_waiting+1)) ;;
            working) a_working=$((a_working+1)) ;;
            # Idle agents only reach the badge under AGENTS=count; see above.
            *)       [ "$AGENTS" = "count" ] && a_idle=$((a_idle+1)) ;;
        esac
    elif [ "$MAIN" = "always" ] || [ "$status" = "working" ] || [ "$status" = "waiting" ]; then
        case "$status" in
            waiting) waiting=$((waiting+1)) ;;
            working) working=$((working+1)) ;;
            *)       idle=$((idle+1)) ;;
        esac
    fi

    # A background job's name says what it is doing ("wallpaper widget inbox
    # review"), which beats the cwd every time. The interactive session's name is
    # a generated handle, so that one keeps the directory.
    if [ "$kind" = "bg" ] && [ -n "$name" ] && [ "$name" != "$short" ]; then
        label="$name"
    else
        label="${cwd##*/}"
    fi
    [ -z "$label" ] && label="?"

    # Mark agents so a count above 1 is self-explanatory when only one terminal
    # is open, and list them after the interactive session.
    if [ "$kind" = "bg" ]; then
        tooltip_agents="${tooltip_agents}${status}\t${label}\n"
    else
        tooltip="${tooltip}${status}\t${label}\n"
    fi
done < <(jq -r 'input_filename as $f
                | [ ($f | split("/") | last | sub("\\.json$"; "")),
                    (.kind // ""), (.status // ""), (.sessionId // ""),
                    (.cwd // ""), (.name // "") ] | @tsv' \
            "${session_files[@]}" 2>/dev/null || true)
fi

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
# Agents count towards it: an agent stuck on a prompt is the whole reason to
# glance at the bar.
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
    # MAIN=working, or it is not running. The agent suffix below carries the
    # label on its own.
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
