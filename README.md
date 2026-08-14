# waybar-claude-status

> See what every Claude Code session is doing - right from your bar.

[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)
[![Shell](https://img.shields.io/badge/Bash-4+-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![waybar](https://img.shields.io/badge/waybar-module-89b4fa?style=flat-square)](https://github.com/Alexays/Waybar)

A [waybar](https://github.com/Alexays/Waybar) module that shows the live status
of your [Claude Code](https://claude.com/claude-code) sessions, driven by Claude
Code hooks - no polling, updates the instant state changes. Built and tested on
Void Linux + sway.

The bar shows one of:

- **claude working** - Claude is actively running (prompt submitted / a tool is executing)
- **claude waiting** - Claude needs your attention (a permission prompt / notification)
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

- **Realtime** - hooks push state on every lifecycle event and signal waybar to
  refresh instantly (`SIGRTMIN+10`); no interval polling of Claude
- **Multi-session aware** - aggregates every open session, with a count and a
  per-session tooltip
- **Self-healing** - crashed sessions that never fired an end hook are pruned
  automatically after `CLAUDE_WAYBAR_STALE_SECS`
- **Themeable** - a CSS class per state (`working` / `waiting` / `idle` / `none`)
- **Zero dependencies** - plain Bash + `jq`

---

## How it works

Claude Code fires [hooks](https://docs.claude.com/en/docs/claude-code/hooks) on
lifecycle events. `claude-hook.sh` catches them, writes a small state file per
session under `~/.cache/claude-waybar/sessions/`, and sends waybar a realtime
signal (`SIGRTMIN+10`) so the bar updates instantly. `claude-status.sh` is the
waybar `exec` module - it aggregates the state files and prints JSON.

The hooks map lifecycle events to states:

| Hook               | State     | Meaning                                            |
|--------------------|-----------|----------------------------------------------------|
| `SessionStart`     | `idle`    | a session opened                                   |
| `UserPromptSubmit` | `working` | you submitted a prompt                             |
| `PreToolUse`       | `working` | a tool is about to run (also clears a stale `waiting`) |
| `PostToolUse`      | `working` | a tool finished (keeps `working` fresh during long turns) |
| `Notification`     | `waiting` | Claude needs input (e.g. a permission prompt)      |
| `Stop`             | `idle`    | the turn finished                                  |
| `SessionEnd`       | `end`     | the session closed (state file removed)            |

> **Why `PreToolUse`?** After a permission prompt, `Notification` sets
> `waiting`. Nothing else would reset it when Claude resumed (a new prompt isn't
> submitted), so the bar could get stuck on `waiting` while actively working.
> Mapping `PreToolUse → working` clears that the moment a tool runs.

> **`Notification` is not only permission prompts.** Claude Code also fires it
> for the "input idle for 60s" nag and for background-job completion / away
> summaries, and both of those arrive *after* the turn has ended - `Stop` has
> already recorded `idle`. Taken at face value they overwrote `idle` with
> `waiting`, parking finished jobs on the bar in amber with nothing to ever
> demote them, so completed background jobs piled up. `waiting` is therefore
> only recorded when the session is currently `working`: a genuine permission
> prompt always interrupts a turn in progress (`UserPromptSubmit` /`PreToolUse`
> have just written `working`, since `PreToolUse` hooks run *before* the
> permission check), while a nag or summary always arrives from `idle`. With no
> prior state file the notification is recorded as `waiting` regardless - better
> a spurious badge than a swallowed permission prompt.

> **The prior-state guard is not enough on its own.** The payload also carries a
> `notification_type`, and the benign kinds are filtered on it directly. The one
> that actually bit was `idle_prompt`, the "Claude is waiting for your input" nag
> fired ~60s after a session goes quiet. Backgrounding a turn (`Ctrl-B`) moves
> the work to a job and fires no `Stop` hook, so the interactive session was
> still recorded as `working` when the nag landed - it passed the guard and left
> the bar reading `claude waiting` with nothing actually waiting, permanently,
> since nothing demotes `waiting`.
>
> Filtered out: `idle_prompt`, `agent_completed`, `auth_success`,
> `push_notification`, `computer_use_enter`/`_exit`, `elicitation_complete`/
> `_response`. It is a denylist rather than an allowlist on purpose - an
> unrecognised or absent type still counts as `waiting`, so a future Claude Code
> release adding a type cannot silently make the module go quiet on a real
> prompt.

There is no polling of Claude itself; the hooks push state as it changes. The
module's `interval` is only a safety net (it also prunes crashed sessions).

> **Note:** Claude Code loads hooks at session start, so the mapping above only
> applies to sessions started *after* you add the hooks. Restart any
> already-running session to pick them up.

### Interrupts

Claude Code fires **no hook when you interrupt a turn** (Esc), so a `working`
session would otherwise stay `working` forever. As a fallback, a `working`
session that hasn't had any hook activity for `CLAUDE_WAYBAR_WORK_TIMEOUT`
seconds (default `90`) is shown as `idle`. The `PreToolUse` / `PostToolUse`
hooks refresh the timestamp during real work so this only triggers once the
turn actually stops. Lower it for snappier recovery after interrupts, or raise
it if you run long single tools with no intermediate hooks.

### Background jobs and agent sessions

Background jobs and agent sessions are *separate* Claude Code sessions with
their own `session_id`, so each one gets its own state file. One terminal
running a couple of agents therefore reports several sessions - that is real,
not a bug, and the tooltip marks those entries `(agent)`.

Working and waiting agents are counted by default, since a background job stuck
on `waiting` is easy to miss otherwise. **Idle agents are not.** Claude Code
keeps pre-warmed `claude bg-spare` workers around to start background jobs
quickly; each one fires `SessionStart` and then sits at `idle` until it is
claimed, so counting idle agents put sessions on the bar that were never
started - the classic symptom being a stray `1 idle` next to your real agents.
A finished agent whose process lingers looks the same. They stay in the
tooltip, just out of the badge.

Spares are also filtered out directly, which matters because an unclaimed one
does not always sit at `idle` - it can fire `Notification` and land on
`waiting`, turning the whole badge amber as if a permission prompt were pending
when nothing was ever started. A real session has a transcript at
`~/.claude/projects/<slugged-cwd>/<session_id>.jsonl`; a spare has a state file
and a live PID but no transcript until it is claimed and given work. Agents
without one are dropped from the badge *and* the tooltip, whatever their state.
Point `CLAUDE_WAYBAR_PROJECTS_DIR` elsewhere if your transcripts live outside
`~/.claude/projects`, or set it empty to disable the check. If the directory for
a session's cwd does not exist at all the check is skipped rather than hiding
every agent.

### Background jobs blocked on you

A background job that finishes its turn asking you a question fires no hook that
says so. The turn ended, so `Stop` has already written `idle`, and `Notification`
only covers prompts that interrupt a turn mid-flight - so the one session
actually waiting on you sat on the bar in grey.

Claude Code records this itself: each background job keeps a
`~/.claude/jobs/<job>/state.json`, and a job waiting on you is in state
`blocked`. Any session whose id appears there is shown as `waiting` regardless of
what the hooks last recorded, applied after the `working` timeout so it cannot be
demoted back to `idle`. Point `CLAUDE_WAYBAR_JOBS_DIR` elsewhere if your jobs
live outside `~/.claude/jobs`, or set it empty to disable the check; without
`jq` the check is skipped rather than failing.

Set `CLAUDE_WAYBAR_AGENTS=count` for the old behaviour (idle agents counted
too), or `CLAUDE_WAYBAR_AGENTS=hide` to report only the session you are typing
in; hidden sessions are still pruned, so nothing accumulates.

The interactive session is counted **only while it is actually working** - you
are already looking at that terminal, so an idle or waiting one does not need a
badge, and folding it in would report 4 sessions when you started 3 agents. It
still appears in the tooltip. Set `CLAUDE_WAYBAR_MAIN=always` to count it in
every state, which is what you want if you keep sessions on other workspaces
and want their permission prompts to reach the bar.

So the label reads:

| Situation                        | Label                |
|----------------------------------|----------------------|
| terminal working, no agents      | `claude working`     |
| terminal working, 3 agents       | `claude working +3`  |
| terminal idle, 3 agents working  | `claude +3`          |
| terminal working, 2 agents working + 1 idle | `claude working +2` |
| terminal idle, no agents         | *(module collapses)* |
| terminal idle, only idle agents  | *(module collapses)* |

Agents are *always* the `+N` suffix - they never occupy the main slot. When
there is nothing to say about the interactive session (idle or waiting under the
default `CLAUDE_WAYBAR_MAIN=working`, or it has not registered yet) the label is
just `claude +N`, not a breakdown that reads as though those agents were
terminals you were sitting in front of.

The `+N` suffix is coloured by the agents' own highest-priority state, so a
background job hitting a permission prompt turns it amber even while your own
session is happily working.

The owning PID is resolved by walking up from the hook to the nearest process
named `claude` **or** `claude.exe` - agent sessions run as the latter, nested
under the interactive `claude`. Matching only `claude` would attribute every
agent to the top-level session, which outlives them all, so their state files
would never be pruned and phantom sessions would pile up in the bar.

---

## Install

```sh
./install.sh
```

Then follow the three snippets it prints - merge them into:

- `~/.config/waybar/config` - the `custom/claude` module (see `install.sh` output)
- `~/.config/waybar/style.css` - colours, from `style.css.example`
- `~/.claude/settings.json` - the hooks, from `claude-settings.json.example`

Reload waybar (`pkill -SIGUSR2 waybar`) and start a Claude Code session.

---

## Configuration

Environment variables (set them for both waybar and your shell, or export in
your session):

| Variable                     | Default                              | Meaning |
|------------------------------|--------------------------------------|---------|
| `CLAUDE_WAYBAR_STATE_DIR`    | `~/.cache/claude-waybar/sessions`    | where per-session state lives |
| `CLAUDE_WAYBAR_SIGNAL`       | `10`                                 | waybar `SIGRTMIN+N` signal number (must match the `signal` in your module) |
| `CLAUDE_WAYBAR_STALE_SECS`   | `86400`                              | drop sessions older than this many seconds |
| `CLAUDE_WAYBAR_WORK_TIMEOUT` | `90`                                 | a `working` session idle this long (no hook activity) is shown as `idle` (interrupt fallback) |
| `CLAUDE_WAYBAR_AGENTS`       | `active`                             | `active` counts only working/waiting background/agent sessions as a `+N` suffix; `count` counts idle ones too; `hide` reports only the interactive session |
| `CLAUDE_WAYBAR_MAIN`         | `working`                            | `working` counts the interactive session only while it is working; `always` counts it in every state |
| `CLAUDE_WAYBAR_PROJECTS_DIR` | `~/.claude/projects`                 | where Claude Code keeps session transcripts; used to tell a real agent from an unclaimed pre-warmed spare. Set empty to disable the check |
| `CLAUDE_WAYBAR_JOBS_DIR`     | `~/.claude/jobs`                     | where Claude Code keeps background-job state; a job in state `blocked` is shown as `waiting`. Set empty to disable the check |
| `CLAUDE_WAYBAR_COLOR_WAITING`/`_WORKING`/`_IDLE` | `#e0af68`/`#9ece6a`/`#7f849c` | per-state colours for the mixed-session breakdown |

If you already use `SIGRTMIN+10` for another module, pick a free number and set
it in both the module's `signal` and `CLAUDE_WAYBAR_SIGNAL`.

---

## License

MIT - see [LICENSE](./LICENSE).
