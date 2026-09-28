#!/usr/bin/env bash
# Bound to prefix+S. Runs a normal resurrect save, then keeps a permanent
# labeled copy (snapshot_<label>_<timestamp>.txt) that resurrect's own
# remove_old_backups pruning and continuum's autosave can't touch, since
# both only ever operate on tmux_resurrect_*.txt / the "last" symlink.
set -euo pipefail

PLUGIN_DIR="$HOME/.config/tmux/plugins/tmux-resurrect"
source "$PLUGIN_DIR/scripts/helpers.sh"
RESURRECT_DIR="$(resurrect_dir)"

label="${1:-unnamed}"
label="${label// /_}"

"$PLUGIN_DIR/scripts/save.sh" quiet

latest="$(readlink -f "$RESURRECT_DIR/last")"
ts="$(date +"%Y%m%dT%H%M%S")"
dest="$RESURRECT_DIR/snapshot_${label}_${ts}.txt"
cp "$latest" "$dest"

tmux display-message "Snapshot saved: ${label}"
