#!/usr/bin/env bash
# Bound to prefix+S / prefix+Ctrl-s.
# Saves a named snapshot with an explicit, non-empty, unique name.
# Rejects duplicate names.
set -euo pipefail

raw_label="${1:-}"
label="$(echo "$raw_label" | xargs)"
label="${label// /_}"

if [ -z "$label" ]; then
  tmux display-message "Ошибка: имя снапшота обязательно!"
  exit 1
fi

if [[ ! "$label" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  tmux display-message "Ошибка: недопустимые символы в имени снапшота!"
  exit 1
fi

PLUGIN_DIR="$HOME/.config/tmux/plugins/tmux-resurrect"
source "$PLUGIN_DIR/scripts/helpers.sh"
RESURRECT_DIR="$(resurrect_dir)"

shopt -s nullglob
existing=( "$RESURRECT_DIR"/snapshot_"${label}"_*.txt )
shopt -u nullglob

if [ ${#existing[@]} -gt 0 ]; then
  tmux display-message "Ошибка: снапшот с именем '${label}' уже существует!"
  exit 1
fi

"$PLUGIN_DIR/scripts/save.sh" quiet

latest="$(readlink -f "$RESURRECT_DIR/last")"
ts="$(date +"%Y%m%dT%H%M%S")"
dest="$RESURRECT_DIR/snapshot_${label}_${ts}.txt"
cp "$latest" "$dest"

# Point 'last' to the new named snapshot
ln -sf "$(basename "$dest")" "$RESURRECT_DIR/last"

# Remove any intermediate unnamed autosaves produced by save.sh
rm -f "$RESURRECT_DIR"/tmux_resurrect_*.txt

tmux display-message "Снапшот '${label}' успешно сохранён"
