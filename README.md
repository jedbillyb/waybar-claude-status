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

If more than one session is active the label gains a count, e.g.
`claude working (2)`, and the tooltip lists each session by its working
directory. Priority is **waiting > working > idle**.

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
| `PreToolUse`       | `working` | a tool is running (also clears a stale `waiting`)  |
| `Notification`     | `waiting` | Claude needs input (e.g. a permission prompt)      |
| `Stop`             | `idle`    | the turn finished                                  |
| `SessionEnd`       | `end`     | the session closed (state file removed)            |

> **Why `PreToolUse`?** After a permission prompt, `Notification` sets
> `waiting`. Nothing else would reset it when Claude resumed (a new prompt isn't
> submitted), so the bar could get stuck on `waiting` while actively working.
> Mapping `PreToolUse → working` clears that the moment a tool runs.

There is no polling of Claude itself; the hooks push state as it changes. The
module's `interval` is only a safety net (it also prunes crashed sessions).

> **Note:** Claude Code loads hooks at session start, so the mapping above only
> applies to sessions started *after* you add the hooks. Restart any
> already-running session to pick them up.

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

If you already use `SIGRTMIN+10` for another module, pick a free number and set
it in both the module's `signal` and `CLAUDE_WAYBAR_SIGNAL`.

---

## License

MIT - see [LICENSE](./LICENSE).
