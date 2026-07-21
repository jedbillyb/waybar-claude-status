# waybar-claude-status

A [waybar](https://github.com/Alexays/Waybar) module that shows the live status
of your [Claude Code](https://claude.com/claude-code) sessions, driven by Claude
Code hooks. Built and tested on Void Linux + sway.

The bar shows one of:

- **claude working** — Claude is actively running (after you submit a prompt)
- **claude waiting** — Claude needs your attention (a permission prompt / notification)
- **claude idle** — session is open and waiting for your next prompt
- *(nothing)* — no active sessions

If more than one session is active the label gains a count, e.g.
`claude working (2)`, and the tooltip lists each session by its working
directory. Priority is **waiting > working > idle**.

## How it works

Claude Code fires [hooks](https://docs.claude.com/en/docs/claude-code/hooks) on
lifecycle events. `claude-hook.sh` catches them, writes a small state file per
session under `~/.cache/claude-waybar/sessions/`, and sends waybar a realtime
signal (`SIGRTMIN+10`) so the bar updates instantly. `claude-status.sh` is the
waybar `exec` module — it aggregates the state files and prints JSON.

There is no polling of Claude itself; the hooks push state as it changes. The
module's `interval` is only a safety net (it also prunes crashed sessions).

## Install

```sh
./install.sh
```

Then follow the three snippets it prints — merge them into:

- `~/.config/waybar/config` — the `custom/claude` module (see `install.sh` output)
- `~/.config/waybar/style.css` — colours, from `style.css.example`
- `~/.claude/settings.json` — the hooks, from `claude-settings.json.example`

Reload waybar (`pkill -SIGUSR2 waybar`) and start a Claude Code session.

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

## License

MIT
