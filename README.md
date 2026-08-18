# waybar-claude-status

> See what every Claude Code session is doing - right from your bar.

[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)
[![Shell](https://img.shields.io/badge/Bash-4+-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![waybar](https://img.shields.io/badge/waybar-module-89b4fa?style=flat-square)](https://github.com/Alexays/Waybar)

A [waybar](https://github.com/Alexays/Waybar) module that shows the live status
of your [Claude Code](https://claude.com/claude-code) sessions, read straight
from the state Claude Code publishes about itself. Built and tested on Void
Linux + sway.

The bar shows one of:

- **claude working** - Claude is actively running (prompt submitted / a tool is executing)
- **claude waiting** - Claude needs your attention (a permission prompt, a sandbox request, any open dialog)
- **claude idle** - session is open and waiting for your next prompt
- *(nothing)* - no active sessions

With several sessions in the **same** state the label gains a count, e.g.
`claude working (2)`. When they **differ** it shows a per-state breakdown -
`claude  1 waiting  1 working` - so a working+idle pair never reads as two
working. The colour follows the highest-priority state present
(**waiting > working > idle**), and the tooltip lists each session by its
working directory.

---

## Features

- **Truthful** - reports the status Claude Code itself publishes, rather than
  reconstructing it from an event stream that has gaps
- **Realtime** - an optional one-line hook signals waybar (`SIGRTMIN+10`) so the
  bar updates the instant something changes, instead of on the poll interval
- **Multi-session aware** - aggregates every open session, with a count and a
  per-session tooltip
- **Stateless** - keeps no state of its own, so there is nothing to get stuck,
  go stale or need pruning
- **Themeable** - a CSS class per state (`working` / `waiting` / `idle` / `none`)
- **Zero dependencies** - plain Bash + `jq`

---

## How it works

`claude-status.sh` is the waybar `exec` module. It reads **Claude Code's own live
state files** and prints JSON. It keeps no state of its own.

| File | Fields used | What it settles |
|------|-------------|-----------------|
| `~/.claude/sessions/<pid>.json` | `kind` (`interactive`\|`bg`\|`daemon`\|`daemon-worker`), `status` (`busy`\|`shell`\|`idle`\|`waiting`), `waitingFor`, `sessionId`, `cwd`, `name` | which sessions exist and what each one is doing |
| `~/.claude/jobs/<short-id>/state.json` | `sessionId` | which background sessions are real jobs rather than unclaimed spares |

Classification is one pass over `sessions/*.json`:

```
dead pid                       -> skip (Claude Code does not always clean up)
no status field                -> skip (the session publishes nothing to render)
kind = daemon | daemon-worker  -> skip (Claude Code's own plumbing)
agent with no job dir          -> unclaimed pre-warmed spare, skip
status = waiting               -> waiting
status = busy | shell          -> working
otherwise                      -> idle
```

That is the whole rule. There is no inference step.

`status` has four values, not three. **`shell`** means the session is running a
shell command: it is working, and mapping it to `idle` (the obvious default for
an unrecognised value) puts a busy agent on the bar in grey. **`kind`** likewise
has four: `daemon` and `daemon-worker` are Claude Code's own background daemon
and its pre-warmed workers, which you never started and cannot act on, so they
are dropped rather than counted as the terminal you are typing in.

### `status: waiting` is published, not guessed

The key field is `status`, and in particular its `waiting` value. Claude Code
computes it internally as roughly:

```js
// any dialog blocking the user?  sandbox request, elicitation prompt,
// managed-settings prompt, open dialog, pending worker request ...
const reason = waitingReason(state);
if (reason !== undefined) return { status: "waiting", waitingFor: reason };
return { status: state.isLoading || state.delegatedActive ? "busy" : "idle" };
```

So `waiting` already means exactly "a human has to do something", for
interactive sessions and background jobs alike, and `waitingFor` says which kind
("sandbox request", "input needed") - which the tooltip shows in brackets. The
module renders that field and adds nothing to it.

### Why not hooks?

It used to work the other way round: hooks drove a state machine, one event at a
time, and that is what made the module lie.

Hooks are *events*, and several transitions fire no event at all - backgrounding
a turn fires no `Stop`, a job going `blocked` fires nothing, an `Esc` interrupt
fires nothing. A state machine fed only by those events gets **stuck**, and each
fix for one stuck case (activity timeouts, orphan pruning by pid,
transcript-presence checks, `notification_type` denylists, prior-state guards)
was another guess layered on the last.

The case that finally settled it: backgrounding a turn with `Ctrl-B` fires no
`Stop`, so the session stayed recorded as `working`; the `idle_prompt` nag ~60s
later then looked exactly like a genuine mid-turn permission prompt, and since
nothing ever demotes `waiting`, the bar sat on `claude waiting` permanently with
nothing waiting. No amount of event filtering fixes that, because the missing
event is the problem.

Reading what Claude Code already publishes removed every one of those
heuristics, along with that entire class of bug. `CLAUDE_WAYBAR_WORK_TIMEOUT`,
`CLAUDE_WAYBAR_STALE_SECS`, `CLAUDE_WAYBAR_STATE_DIR`, `CLAUDE_WAYBAR_PROJECTS_DIR`
and the hook state files under `~/.cache/claude-waybar/` are all gone with them.

### What the hook still does

`claude-hook.sh` survives, reduced to one job: `pkill -RTMIN+10 waybar`, so the
module re-runs the moment something changes instead of waiting up to a full poll
interval. It derives nothing, stores nothing, and reads nothing from the hook
payload. It pokes waybar twice (immediately, then a second later) because the
hook can run fractionally before Claude Code has finished writing the new status.

**The module works with no hooks at all**, it just refreshes on its `interval`.
Every hook entry in `claude-settings.json.example` runs the same argument-free
command, and old entries that still pass a status word keep working, since the
arguments are ignored.

### Background jobs and agent sessions

Background jobs and agent sessions are *separate* Claude Code sessions with
their own `sessionId`, so each one gets its own `sessions/<pid>.json`. One
terminal running a couple of agents therefore reports several sessions - that is
real, not a bug. The tooltip lists them after the interactive session, each under
the job's own name (`wallpaper widget inbox review`) rather than a bare
directory, so you can tell which one wants you.

Working and waiting agents are counted by default, since a background job stuck
on `waiting` is easy to miss otherwise. **Idle agents are not.** Claude Code
keeps pre-warmed `claude bg-spare` workers around to start background jobs
quickly; each sits at `idle` until claimed, so counting idle agents put sessions
on the bar that were never started. A finished agent whose process lingers looks
the same. They stay in the tooltip, just out of the badge.

Spares are filtered out directly: a real background job has a directory under
`~/.claude/jobs/`, an unclaimed spare does not. Agents without one are dropped
from the badge *and* the tooltip, whatever their state.

A session that publishes **no `status` field at all** is skipped the same way.
Some SDK entrypoints (an embedded `sdk-py` session, say) write a session file
with no status in it, and there is nothing honest to render for those, so they
stay off the bar rather than being guessed at as idle.

> **Not `jobs/state.json`.** A background job's `state.json` also carries a
> `state` (`working`|`blocked`|`done`|`failed`), and an earlier version read
> `blocked` as "needs input". It is derived *downstream* of the session status
> and lags behind it - answering a blocked job resumes it immediately while
> `state` can still read `blocked` a minute later - which reported jobs as
> waiting long after they went back to work. The session file is the upstream
> value, so that is the one to read, and the whole busy-vetoes-stale-blocked
> dance it needed is gone. The job directory is still used, but only for its
> existence.

Set `CLAUDE_WAYBAR_AGENTS=count` to count idle agents too, or
`CLAUDE_WAYBAR_AGENTS=hide` to report only the session you are typing in.

The interactive session is counted **only while it is working or waiting** - you
are already looking at that terminal, so an idle one does not need a badge, and
folding it in would report 4 sessions when you started 3 agents. It still appears
in the tooltip. Set `CLAUDE_WAYBAR_MAIN=always` to count it in every state.

So the label reads:

| Situation                        | Label                |
|----------------------------------|----------------------|
| terminal working, no agents      | `claude working`     |
| terminal working, 3 agents       | `claude working +3`  |
| terminal idle, 3 agents working  | `claude +3`          |
| terminal working, 2 agents working + 1 idle | `claude working +2` |
| terminal idle, 1 agent needing input | `claude +1 waiting` |
| terminal idle, 3 agents, 2 needing input | `claude +3 (2 waiting)` |
| terminal working, 1 agent needing input | `claude working +1 waiting` |
| terminal idle, no agents         | *(module collapses)* |
| terminal idle, only idle agents  | *(module collapses)* |

An agent that needs input says so **in words**, not just in colour. Colour alone
did not carry it: "3 agents running" and "one of them is blocked on you" both
rendered as `claude +3`, told apart only by the hue of a two-character span, and
when the interactive session had a word of its own the label read
`claude working` while something sat waiting on an answer. Noticing that is the
entire job of this module, so the suffix spells it out. Working and idle agents
are unchanged - the bare `+N` is right for them.

Agents are *always* the `+N` suffix - they never occupy the main slot. When
there is nothing to say about the interactive session (idle under the default
`CLAUDE_WAYBAR_MAIN=working`, or it is not running) the label is just
`claude +N`, not a breakdown that reads as though those agents were terminals you
were sitting in front of.

The `+N` suffix is coloured by the agents' own highest-priority state, so a
background job hitting a permission prompt turns it amber even while your own
session is happily working.

---

## Install

```sh
./install.sh
```

Then follow the snippets it prints - merge them into:

- `~/.config/waybar/config` - the `custom/claude` module (see `install.sh` output)
- `~/.config/waybar/style.css` - colours, from `style.css.example`
- `~/.claude/settings.json` - *optional*, from `claude-settings.json.example`;
  these only make the bar refresh instantly instead of on the poll interval

Reload waybar (`pkill -SIGUSR2 waybar`) and start a Claude Code session.

---

## Configuration

Environment variables (set them for both waybar and your shell, or export in
your session):

| Variable                     | Default                              | Meaning |
|------------------------------|--------------------------------------|---------|
| `CLAUDE_WAYBAR_SIGNAL`       | `10`                                 | waybar `SIGRTMIN+N` signal number the hook sends (must match the `signal` in your module) |
| `CLAUDE_WAYBAR_AGENTS`       | `active`                             | `active` counts only working/waiting background/agent sessions as a `+N` suffix; `count` counts idle ones too; `hide` reports only the interactive session |
| `CLAUDE_WAYBAR_MAIN`         | `working`                            | `working` counts the interactive session only while it is working; `always` counts it in every state |
| `CLAUDE_WAYBAR_JOBS_DIR`     | `~/.claude/jobs`                     | Claude Code's background-job directories; only their existence is read, to tell a real agent from an unclaimed spare |
| `CLAUDE_WAYBAR_SESSIONS_DIR` | `~/.claude/sessions`                 | Claude Code's live per-process session state - the source of truth for what every session is doing |
| `CLAUDE_WAYBAR_COLOR_WAITING`/`_WORKING`/`_IDLE` | `#e0af68`/`#9ece6a`/`#7f849c` | per-state colours for the mixed-session breakdown |

If you already use `SIGRTMIN+10` for another module, pick a free number and set
it in both the module's `signal` and `CLAUDE_WAYBAR_SIGNAL`.

---

## License

MIT - see [LICENSE](./LICENSE).
