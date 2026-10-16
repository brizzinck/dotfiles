#!/usr/bin/env bash
# Bound to prefix+S / prefix+Ctrl-s.
# Saves a named snapshot with an explicit, non-empty, unique name.
# Rejects duplicate names unless --replace is given, in which case older
# snapshots with the same name are removed after the new one is written.
#
#   snapshot-save.sh <name>
#   snapshot-save.sh --replace <name>
set -euo pipefail

replace=false
if [ "${1:-}" = "--replace" ]; then
  replace=true
  shift
fi

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

# Exact label match: snapshot_<label>_YYYYMMDDTHHMMSS.txt (so 'foo' never matches 'foo_bar')
TS_GLOB='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]'
shopt -s nullglob
existing=( "$RESURRECT_DIR"/snapshot_"${label}"_$TS_GLOB.txt )
shopt -u nullglob

if [ ${#existing[@]} -gt 0 ] && [ "$replace" = false ]; then
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

# An unnamed (numeric) session takes the snapshot's name, so later saves reuse it
cur="$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")"
if [[ "$cur" =~ ^[0-9]+$ ]] && ! tmux has-session -t "=$label" 2>/dev/null; then
  tmux rename-session -t "=$cur" "$label"
fi

# Drop the older snapshots this one replaces
for f in "${existing[@]}"; do
  [ "$f" != "$dest" ] && rm -f "$f"
done

if [ "$replace" = true ] && [ ${#existing[@]} -gt 0 ]; then
  tmux display-message "Снапшот '${label}' обновлён"
else
  tmux display-message "Снапшот '${label}' успешно сохранён"
fi
