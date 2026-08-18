#!/bin/bash
# claude-status.sh - waybar custom module for Claude Code session status.
#
# Emits one line of JSON ({"text","class","tooltip"}) for waybar to render.
#
# Priority when several sessions are active:  waiting > working > idle.
#
# ---------------------------------------------------------------------------
# Where the state comes from
# ---------------------------------------------------------------------------
# Claude Code publishes, per process, exactly the state this module wants:
#
#   ~/.claude/sessions/<pid>.json
#       kind        interactive | bg | daemon | daemon-worker
#       status      busy | shell | idle | waiting
#       waitingFor  why it is waiting, when status is 'waiting'
#       sessionId, cwd, name, jobId
#
# 'waiting' is computed by Claude Code itself and already covers every case
# where a human has to act: a sandbox/permission request, an elicitation
# prompt, a managed-settings prompt, any open dialog, a pending worker request.
# It applies to interactive sessions as much as to background jobs.
#
# So that field is the whole answer, and this module is a renderer, not a state
# machine. Earlier versions reconstructed status from hook events and lied
# constantly, because hooks are events and several transitions fire none:
# backgrounding a turn fires no Stop, a job going blocked fires nothing, an Esc
# interrupt fires nothing. Anything derived from that record gets stuck, and
# every fix for one stuck case was another guess layered on the last. Notably a
# backgrounded turn left a permanent false 'waiting' that nothing could clear.
#
# ~/.claude/jobs/<short-id>/state.json is read for one thing only: whether a
# background session has a job directory at all. Its own 'state' field is
# derived downstream of the session status and lags behind it, so it is not
# consulted for status. See the README.
set -euo pipefail

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
# terminal does not need a badge. 'waiting' is always counted regardless - a
# pending prompt is exactly the case the badge exists for, especially when
# you've alt-tabbed away. 'always' additionally counts idle.
MAIN="${CLAUDE_WAYBAR_MAIN:-working}"

shopt -s nullglob

# ---------------------------------------------------------------------------
# Read Claude Code's state. Two jq invocations total, whatever the session count.
# ---------------------------------------------------------------------------

# Session ids that have a background job directory. A bg session missing from
# this set is an unclaimed pre-warmed `claude bg-spare` worker: it has a session
# file and a live pid but was never given work, and counting those put phantom
# agents on the bar. Having a job directory is what separates an agent you
# actually started.
declare -A has_job=()
job_files=("$JOBS_DIR"/*/state.json)
if [ "${#job_files[@]}" -gt 0 ]; then
    while IFS= read -r sid; do
        [ -n "$sid" ] && has_job["$sid"]=1
    done < <(jq -r '.sessionId // empty' "${job_files[@]}" 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Classify every live session.
# ---------------------------------------------------------------------------

waiting=0 working=0 idle=0          # the interactive session
a_waiting=0 a_working=0 a_idle=0    # background/agent sessions
tooltip="" tooltip_agents=""

session_files=("$SESSIONS_DIR"/*.json)
if [ "${#session_files[@]}" -gt 0 ]; then
# Fields are separated by US (0x1f), not tab. Tab counts as IFS *whitespace*,
# so bash collapses runs of them into one delimiter and drops empty fields:
# a session with no waitingFor shifted every later column left, which read the
# session id as the status and lost every background job. A non-whitespace
# separator keeps empty fields empty.
while IFS=$'\x1f' read -r pid kind cc_status waiting_for sid cwd name; do
    [ -n "$pid" ] || continue
    # Claude Code owns these files and does not always remove them promptly, so
    # liveness is decided by the process, not the file.
    kill -0 "$pid" 2>/dev/null || continue

    # A session that publishes no status tells us nothing to render. Older CLI
    # builds and some SDK entrypoints (an embedded `sdk-py` session, say) write
    # a session file with no status field at all, and guessing on their behalf
    # is how you get a bar full of sessions the user never started.
    [ -n "$cc_status" ] || continue

    # 'daemon' and 'daemon-worker' are Claude Code's own plumbing: the
    # background daemon and its pre-warmed workers. You never started them and
    # cannot act on them, so they have no business on the bar. Only
    # 'interactive' is the terminal you are typing in; anything else is treated
    # as an agent, which is the conservative reading for a kind added later.
    case "$kind" in
        daemon|daemon-worker) continue ;;
        interactive)          is_agent=0 ;;
        *)                    is_agent=1 ;;
    esac

    if [ "$is_agent" = 1 ]; then
        # No job directory means an unclaimed spare, not an agent you started.
        [ -n "${has_job[$sid]-}" ] || continue
    fi

    # The published status is the answer. No inference, no fallbacks.
    # 'shell' means the session is running a shell command, so it is working:
    # it is emphatically not idle, and nothing is waiting on you.
    case "$cc_status" in
        waiting)    status="waiting" ;;
        busy|shell) status="working" ;;
        *)          status="idle" ;;
    esac

    if [ "$is_agent" = 1 ]; then
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
    short="${sid:0:8}"
    if [ "$is_agent" = 1 ] && [ -n "$name" ] && [ "$name" != "$short" ]; then
        label="$name"
    else
        label="${cwd##*/}"
    fi
    [ -z "$label" ] && label="?"

    # Claude Code says why it is waiting ("sandbox request", "input needed").
    # That is the one thing the tooltip can add that the badge cannot.
    [ "$status" = "waiting" ] && [ -n "$waiting_for" ] && label="$label ($waiting_for)"

    # List agents after the interactive session.
    if [ "$is_agent" = 1 ]; then
        tooltip_agents="${tooltip_agents}${status}\t${label}\n"
    else
        tooltip="${tooltip}${status}\t${label}\n"
    fi
done < <(jq -r 'input_filename as $f
                | [ ($f | split("/") | last | sub("\\.json$"; "")),
                    (.kind // ""), (.status // ""), (.waitingFor // ""),
                    (.sessionId // ""), (.cwd // ""), (.name // "") ]
                | join("\u001f")' \
            "${session_files[@]}" 2>/dev/null || true)
fi

tooltip="${tooltip}${tooltip_agents}"

agents=$((a_waiting+a_working+a_idle))
total=$((waiting+working+idle))

if [ $((total+agents)) -eq 0 ]; then
    # No active Claude sessions - emit empty text so the module collapses.
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
    # Nothing to say about the interactive session: it is idle under
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
# this module, the suffix spells it out. Working and idle agents are unchanged -
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
