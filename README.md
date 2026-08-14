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

`claude-status.sh` is the waybar `exec` module. It reads **Claude Code's own live
state files** and prints JSON:

| File | Fields used | What it settles |
|------|-------------|-----------------|
| `~/.claude/sessions/<pid>.json` | `kind` (`interactive`\|`bg`), `status` (`busy`\|`idle`), `sessionId`, `cwd`, `name` | which sessions exist, and which are working |
| `~/.claude/jobs/<short-id>/state.json` | `state` (`working`\|`blocked`\|`done`\|`failed`), `sessionId` | which background jobs need input (`blocked`) |

Classification is one pass over `sessions/*.json`:

```
dead pid                     -> skip (Claude Code does not always clean up)
kind=bg with no job dir      -> unclaimed pre-warmed spare, skip
job state = blocked, not busy-> waiting
session status = busy        -> working
otherwise                    -> idle
```

The interactive session gets one extra check, described under
[Permission prompts](#permission-prompts) below.

### Why not hooks?

It used to work the other way round: hooks drove a state machine and the state
files were the only input. Hooks are *events*, and several transitions fire no
event at all - backgrounding a turn fires no `Stop`, a job going `blocked` fires
nothing, an `Esc` interrupt fires nothing. A state machine fed only by those
events gets stuck, and each fix for one stuck case (activity timeouts, orphan
pruning by pid, transcript-presence checks, notification filtering) was another
guess layered on the last. Reading what Claude Code already publishes removed all
of them, along with that entire class of bug.

### Permission prompts

One thing the state files do **not** distinguish: a permission prompt keeps the
interactive session `busy`, exactly like ordinary work. That is the one case
hooks still cover.

Claude Code fires [hooks](https://docs.claude.com/en/docs/claude-code/hooks) on
lifecycle events. `claude-hook.sh` catches them, writes a small state file per
session under `~/.cache/claude-waybar/sessions/`, and sends waybar a realtime
signal (`SIGRTMIN+10`) so the bar updates instantly. The module reads only the
**interactive** session's entry, and only to see whether it is `waiting` - and
ignores that if the session has since gone `idle`, which means the turn ended and
the flag is stale. Everything else in the file is used for housekeeping.

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

### Interrupts, and other transitions that fire no hook

Claude Code fires **no hook when you interrupt a turn** (`Esc`), none when you
background one (`Ctrl-B`), and none when a job goes `blocked`. None of that
matters now: the module asks Claude Code what the session is doing rather than
tracking it, so a missing event cannot leave the bar stuck. The previous
activity-timeout fallback (`CLAUDE_WAYBAR_WORK_TIMEOUT`) is gone.

### Background jobs and agent sessions

Background jobs and agent sessions are *separate* Claude Code sessions with
their own `session_id`, so each one gets its own state file. One terminal
running a couple of agents therefore reports several sessions - that is real,
not a bug. The tooltip lists them after the interactive session, each under the
job's own name (`wallpaper widget inbox review`) rather than a bare directory,
so you can tell which one wants you.

Working and waiting agents are counted by default, since a background job stuck
on `waiting` is easy to miss otherwise. **Idle agents are not.** Claude Code
keeps pre-warmed `claude bg-spare` workers around to start background jobs
quickly; each one fires `SessionStart` and then sits at `idle` until it is
claimed, so counting idle agents put sessions on the bar that were never
started - the classic symptom being a stray `1 idle` next to your real agents.
A finished agent whose process lingers looks the same. They stay in the
tooltip, just out of the badge.

Spares are filtered out directly: a real background job has a directory under
`~/.claude/jobs/`, an unclaimed spare does not. Agents without one are dropped
from the badge *and* the tooltip, whatever their state. (This replaced a check
for the presence of a session transcript, and `CLAUDE_WAYBAR_PROJECTS_DIR` with
it.)

### Background jobs blocked on you

A background job that finishes its turn asking you a question fires no hook that
says so - the turn ended, so `Stop` already ran, and `Notification` only covers
prompts that interrupt a turn mid-flight. The one session actually waiting on you
sat on the bar in grey.

Claude Code records it itself: each background job keeps a
`~/.claude/jobs/<job>/state.json`, and a job waiting on you is in state
`blocked`. Point `CLAUDE_WAYBAR_JOBS_DIR` elsewhere if your jobs live outside
`~/.claude/jobs`.

**The job state lags, so it needs a veto.** When you answer a blocked job it
resumes immediately, but its `state.json` can still read `blocked` for a minute
or more - your answer shows up as the job's `detail` while `state` trails behind.
Taken alone that reported jobs as waiting well after they had gone back to work,
and with every counted agent stale-blocked the label read `+3 waiting` while one
of them was visibly working in the job list.

Claude Code also writes a live per-process file at `~/.claude/sessions/<pid>.json`
with `kind` (`interactive`|`bg`) and `status` (`busy`|`idle`|...), and the pid is
already recorded, so a **`busy` session vetoes a stale `blocked`**. Only a
positive `busy` counts: a missing, unreadable or malformed file leaves the block
alone, so the veto can never swallow a real prompt. Point
`CLAUDE_WAYBAR_SESSIONS_DIR` elsewhere or set it empty to disable it.

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
| `CLAUDE_WAYBAR_STATE_DIR`    | `~/.cache/claude-waybar/sessions`    | where the hook writes its state; only the interactive session's entry is read |
| `CLAUDE_WAYBAR_SIGNAL`       | `10`                                 | waybar `SIGRTMIN+N` signal number (must match the `signal` in your module) |
| `CLAUDE_WAYBAR_STALE_SECS`   | `86400`                              | prune hook state files older than this many seconds |
| `CLAUDE_WAYBAR_AGENTS`       | `active`                             | `active` counts only working/waiting background/agent sessions as a `+N` suffix; `count` counts idle ones too; `hide` reports only the interactive session |
| `CLAUDE_WAYBAR_MAIN`         | `working`                            | `working` counts the interactive session only while it is working; `always` counts it in every state |
| `CLAUDE_WAYBAR_JOBS_DIR`     | `~/.claude/jobs`                     | Claude Code's background-job state; `blocked` means the job needs input, and a job directory is what tells a real agent from an unclaimed spare |
| `CLAUDE_WAYBAR_SESSIONS_DIR` | `~/.claude/sessions`                 | Claude Code's live per-process session state - the primary source: which sessions exist, and which are working |
| `CLAUDE_WAYBAR_COLOR_WAITING`/`_WORKING`/`_IDLE` | `#e0af68`/`#9ece6a`/`#7f849c` | per-state colours for the mixed-session breakdown |

If you already use `SIGRTMIN+10` for another module, pick a free number and set
it in both the module's `signal` and `CLAUDE_WAYBAR_SIGNAL`.

---

## License

MIT - see [LICENSE](./LICENSE).
