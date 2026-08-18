#!/bin/bash
# claude-hook.sh - poke waybar so the Claude module refreshes immediately.
#
# This hook carries no state. Claude Code already publishes what every session
# is doing in ~/.claude/sessions/<pid>.json, and claude-status.sh reads that
# directly; all this does is tell waybar "something changed, re-run the module
# now" instead of waiting up to a full poll interval.
#
# It used to derive the status itself from the hook event stream, and that is
# precisely what made the module lie. Hooks are events, and several transitions
# fire no event at all: backgrounding a turn fires no Stop, a job going blocked
# fires nothing, an Esc interrupt fires nothing. A state machine fed only by
# those events gets permanently stuck - most visibly as a 'waiting' badge with
# nothing waiting, which nothing could ever demote. None of that guesswork is
# needed now, so none of it is here.
#
# Usage (from settings.json hooks):  claude-hook.sh
# Any arguments are ignored, so old settings.json entries that pass a status
# word keep working.
set -euo pipefail

SIGNAL="${CLAUDE_WAYBAR_SIGNAL:-10}"   # waybar SIGRTMIN+N, must match config

# Drain stdin so Claude Code never blocks writing the hook payload at us. We
# have no use for its contents.
cat >/dev/null 2>&1 || true

poke() { pkill -RTMIN+"$SIGNAL" waybar 2>/dev/null || true; }

# Refresh now, then once more a moment later. The hook can run fractionally
# before Claude Code finishes writing the new status to its session file (a
# permission prompt is the case that matters), and the second poke picks up the
# value the first one raced. Cheap enough to do unconditionally.
poke
( sleep 1; poke ) >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
