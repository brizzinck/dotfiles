#!/usr/bin/env bash
# Bound to prefix+R / prefix+Ctrl-r, runs inside a tmux popup. Lists every saved snapshot
# newest first in fzf, so the list scrolls, filters and previews the sessions /
# windows / commands inside each file. The pick becomes resurrect's "last"
# symlink before its restore.sh runs. Supports deleting snapshots via 'd' or 'x'.
#
# Called as:
#   snapshot-restore.sh --preview <file>
#   snapshot-restore.sh --delete <file>
#   snapshot-restore.sh --confirm-delete <file>
#   snapshot-restore.sh --list
set -euo pipefail

PLUGIN_DIR="$HOME/.config/tmux/plugins/tmux-resurrect"
source "$PLUGIN_DIR/scripts/helpers.sh"
RESURRECT_DIR="$(resurrect_dir)"

if [ "${1:-}" = "--preview" ]; then
  f="${2:?snapshot file required}"
  # window lines: window <session> <index> :<name> <active> :<flags> <layout>
  # pane lines:   pane <session> <windex> <active> :<flags> <pindex> <title> :<cwd> <active> <cmd> <pid> <hist>
  awk -F'\t' '
    $1 == "window" { if (!($2 in w)) order[++n] = $2; w[$2]++; name[$2 SUBSEP $3] = substr($4, 2) }
    $1 == "pane"   { panes[++p] = $2 SUBSEP $3 SUBSEP $6 SUBSEP $10 SUBSEP substr($8, 2) }
    END {
      for (i = 1; i <= n; i++) printf "%s (%d windows)\n", order[i], w[order[i]]
      print ""
      printf "  %-12s %-20s %-10s %s\n", "session", "win:name", "cmd", "cwd"
      for (i = 1; i <= p; i++) {
        split(panes[i], f, SUBSEP)
        printf "  %-12s %-20s %-10s %s\n", f[1], f[2] ":" name[f[1] SUBSEP f[2]] (f[3] > 1 ? " ." f[3] : ""), f[4], f[5]
      }
    }' "$f"
  exit 0
fi

# One awk pass over every file: "<path>\t<date>  <label>  <session>(<n>w) ..."
# Filenames: snapshot_<label>_YYYYMMDDTHHMMSS.txt
list() {
  local -a sfiles
  mapfile -t sfiles < <(ls -t "$RESURRECT_DIR"/snapshot_*.txt 2>/dev/null)
  [ ${#sfiles[@]} -gt 0 ] || return 0
  awk -F'\t' '
    function flush(   base, ts, label, date, out, i) {
      if (cur == "") return
      base = cur; sub(/.*\//, "", base)
      ts = substr(base, length(base) - 18, 15)
      label = (base ~ /^snapshot_/) ? substr(base, 10, length(base) - 29) : "-"
      date = substr(ts, 1, 4) "-" substr(ts, 5, 2) "-" substr(ts, 7, 2) " " substr(ts, 10, 2) ":" substr(ts, 12, 2)
      out = ""
      for (i = 1; i <= n; i++) out = out sprintf("%s(%dw) ", order[i], c[order[i]])
      printf "%s\t%s  %-12s  %s\n", cur, date, label, out
    }
    FNR == 1 { flush(); cur = FILENAME; delete c; delete order; n = 0 }
    $1 == "window" { if (!($2 in c)) order[++n] = $2; c[$2]++ }
    END { flush() }
  ' "${sfiles[@]}"
}

if [ "${1:-}" = "--list" ]; then
  list
  exit 0
fi

delete_snapshot() {
  local f="${1:?snapshot file required}"
  if [ -f "$f" ]; then
    rm -f "$f"
    # If this was 'last', update last to the newest remaining snapshot
    if [ -L "$RESURRECT_DIR/last" ]; then
      local last_target
      last_target="$(readlink -f "$RESURRECT_DIR/last" 2>/dev/null || true)"
      local cur_target
      cur_target="$(readlink -f "$f" 2>/dev/null || true)"
      if [ "$last_target" = "$cur_target" ] || [ ! -e "$RESURRECT_DIR/last" ]; then
        local newest
        newest="$(ls -t "$RESURRECT_DIR"/snapshot_*.txt 2>/dev/null | head -n1 || true)"
        if [ -n "$newest" ]; then
          ln -sf "$(basename "$newest")" "$RESURRECT_DIR/last"
        else
          rm -f "$RESURRECT_DIR/last"
        fi
      fi
    fi
  fi
}

if [ "${1:-}" = "--delete" ]; then
  delete_snapshot "${2:?snapshot file required}"
  exit 0
fi

if [ "${1:-}" = "--confirm-delete" ]; then
  f="${2:?snapshot file required}"
  base="$(basename "$f")"
  label="$base"
  if [[ "$base" =~ ^snapshot_(.+)_[0-9]{8}T[0-9]{6}\.txt$ ]]; then
    label="${BASH_REMATCH[1]}"
  fi
  printf "\nDelete snapshot '%s' (%s)? [y/N]: " "$label" "$base"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    delete_snapshot "$f"
    echo "Snapshot deleted."
    sleep 0.4
  else
    echo "Cancelled."
    sleep 0.3
  fi
  exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed (pacman -S fzf)."
  read -n1 -r -p "press any key..."
  exit 1
fi

initial="$(list)"
if [ -z "$initial" ]; then
  echo "No snapshots found."
  read -n1 -r -p "press any key..."
  exit 0
fi

# The list is the shared modal fzf (INSERT opens, Esc = NORMAL with j/k g/G, d/x delete a snapshot, Enter restore,
# q quit; ua/ru twins come from the library). NORMAL-mode extras travel in FZF_MENU_NORMAL_BINDS.
FZF_MENU="$HOME/.local/bin/fzf-menu"
if [ ! -x "$FZF_MENU" ]; then
  echo "fzf-menu is missing ($FZF_MENU): run stow in ~/dotfiles"
  read -n1 -r -p "press any key..."
  exit 1
fi
reload="reload(bash '$0' --list)"
export FZF_MENU_NORMAL_BINDS="d:execute(bash '$0' --confirm-delete {1})+$reload
x:execute(bash '$0' --confirm-delete {1})+$reload"
chosen="$(printf "%s\n" "$initial" | "$FZF_MENU" --here -p snapshots --delimiter=$'\t' --with-nth=2.. \
  --header='Enter restore   Esc: normal mode   NORMAL: j/k g/G move   J/K preview   d delete   i or / filter   q quit' \
  --bind 'alt-j:preview-down' --bind 'alt-k:preview-up' \
  --preview="bash '$0' --preview {1}" \
  --preview-window='right,45%,wrap')" || exit 0

chosen="${chosen%%$'\t'*}"
[ -n "$chosen" ] || exit 0

ln -sf "$(basename "$chosen")" "$RESURRECT_DIR/last"
"$PLUGIN_DIR/scripts/restore.sh"

echo
echo "Restored: $(basename "$chosen")"
sleep 1
