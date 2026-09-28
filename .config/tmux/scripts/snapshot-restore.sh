#!/usr/bin/env bash
# Bound to prefix+R, runs inside a tmux popup. Lists every saved snapshot
# (autosaves from continuum + labeled ones from snapshot-save.sh) with date,
# label and per-session window count, then points resurrect's "last" symlink
# at whichever one is picked before calling its restore.sh.
set -euo pipefail

PLUGIN_DIR="$HOME/.config/tmux/plugins/tmux-resurrect"
source "$PLUGIN_DIR/scripts/helpers.sh"
RESURRECT_DIR="$(resurrect_dir)"

mapfile -t files < <(ls -t "$RESURRECT_DIR"/tmux_resurrect_*.txt "$RESURRECT_DIR"/snapshot_*.txt 2>/dev/null)

if [ ${#files[@]} -eq 0 ]; then
  echo "No snapshots found."
  read -n1 -r -p "press any key..."
  exit 0
fi

describe() {
  local f="$1" base label ts_raw ts_fmt sessions
  base="$(basename "$f")"
  if [[ "$base" =~ ^snapshot_(.+)_([0-9]{8}T[0-9]{6})\.txt$ ]]; then
    label="${BASH_REMATCH[1]}"
    ts_raw="${BASH_REMATCH[2]}"
  elif [[ "$base" =~ ^tmux_resurrect_([0-9]{8}T[0-9]{6})\.txt$ ]]; then
    label="-"
    ts_raw="${BASH_REMATCH[1]}"
  else
    label="-"
    ts_raw=""
  fi
  if [ -n "$ts_raw" ]; then
    ts_fmt="$(date -d "${ts_raw:0:8} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$ts_raw")"
  else
    ts_fmt="?"
  fi
  sessions="$(awk -F'\t' '$1=="window"{c[$2]++} END{for (s in c) printf "%s(%dw) ", s, c[s]}' "$f")"
  printf "%-16s  %-12s  %s\n" "$ts_fmt" "$label" "$sessions"
}

echo "Snapshots (newest first):"
echo
for i in "${!files[@]}"; do
  printf "%3d) %s\n" "$((i + 1))" "$(describe "${files[$i]}")"
done
echo
read -r -p "Number to restore (empty = cancel): " choice

[ -z "$choice" ] && exit 0
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
  echo "Invalid choice."
  read -n1 -r -p "press any key..."
  exit 1
fi

chosen="${files[$((choice - 1))]}"
ln -sf "$(basename "$chosen")" "$RESURRECT_DIR/last"
"$PLUGIN_DIR/scripts/restore.sh"

echo
echo "Restored: $(basename "$chosen")"
sleep 1
