#!/bin/bash
# install.sh - symlink the scripts into ~/.config/waybar and print the config
# and (optional) Claude Code hook snippets you need to add.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAYBAR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

mkdir -p "$WAYBAR_DIR"
chmod +x "$REPO_DIR/claude-hook.sh" "$REPO_DIR/claude-status.sh"
ln -sf "$REPO_DIR/claude-status.sh" "$WAYBAR_DIR/claude-status.sh"
ln -sf "$REPO_DIR/claude-hook.sh"   "$WAYBAR_DIR/claude-hook.sh"

echo "Linked:"
echo "  $WAYBAR_DIR/claude-status.sh -> $REPO_DIR/claude-status.sh"
echo "  $WAYBAR_DIR/claude-hook.sh   -> $REPO_DIR/claude-hook.sh"
cat <<'EOF'

Next steps
----------
1. Add "custom/claude" to "modules-right" (or wherever you like) in
   ~/.config/waybar/config, and add this module definition:

    "custom/claude": {
        "exec": "~/.config/waybar/claude-status.sh",
        "return-type": "json",
        "interval": 10,
        "signal": 10,
        "tooltip": true
    }

2. Add the CSS in style.css.example to ~/.config/waybar/style.css.

3. Optional: add the hooks in claude-settings.json.example to
   ~/.claude/settings.json (merge the "hooks" block into your existing one).
   They carry no state - they only poke waybar so the module refreshes the
   instant something changes instead of on its poll interval. The module reads
   Claude Code's own ~/.claude/sessions/<pid>.json and works fine without them.

4. Reload waybar:  pkill -SIGUSR2 waybar   (or restart it)
EOF
