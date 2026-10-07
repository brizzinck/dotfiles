#!/usr/bin/env bash
# Bound to prefix+R, runs inside a tmux popup. Lists every saved snapshot
# (autosaves from continuum + labeled ones from snapshot-save.sh) newest
# first in fzf, so the list scrolls, filters and previews the sessions /
# windows / commands inside each file. The pick becomes resurrect's "last"
# symlink before its restore.sh runs.
#
# Called as `snapshot-restore.sh --preview <file>` by fzf for the preview pane.
set -euo pipefail

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

PLUGIN_DIR="$HOME/.config/tmux/plugins/tmux-resurrect"
source "$PLUGIN_DIR/scripts/helpers.sh"
RESURRECT_DIR="$(resurrect_dir)"

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed (pacman -S fzf)."
  read -n1 -r -p "press any key..."
  exit 1
fi

mapfile -t files < <(ls -t "$RESURRECT_DIR"/snapshot_*.txt 2>/dev/null)

if [ ${#files[@]} -eq 0 ]; then
  echo "No snapshots found."
  read -n1 -r -p "press any key..."
  exit 0
fi

# One awk pass over every file: "<path>\t<date>  <label>  <session>(<n>w) ..."
# Filenames: tmux_resurrect_YYYYMMDDTHHMMSS.txt / snapshot_<label>_YYYYMMDDTHHMMSS.txt
list() {
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
  ' "${files[@]}"
}

# Modal vim keys. Normal mode (default): j/k move, g/G first/last, C-d/C-u
# half page, C-f/C-b page, J/K scroll preview, i / a / "/" enter insert mode,
# q or esc quit. Insert mode: type to filter, esc back to normal (query stays).
# Mode state lives in the prompt text, which fzf exports to transform as $FZF_PROMPT.
NORMAL_KEYS='j,k,g,G,J,K,i,a,/,q'
chosen="$(list | fzf \
  --layout=reverse --delimiter=$'\t' --with-nth=2.. --no-multi --cycle \
  --prompt='N> ' \
  --header='j/k g/G C-d/C-u move   J/K preview   i or / filter   esc normal   enter restore   q quit' \
  --bind 'j:down,k:up,g:first,G:last,J:preview-down,K:preview-up,q:abort' \
  --bind 'ctrl-d:half-page-down,ctrl-u:half-page-up,ctrl-f:page-down,ctrl-b:page-up' \
  --bind "i:unbind($NORMAL_KEYS)+change-prompt(I> )" \
  --bind "a:unbind($NORMAL_KEYS)+change-prompt(I> )" \
  --bind "/:unbind($NORMAL_KEYS)+change-prompt(I> )+clear-query" \
  --bind "esc:transform:[ \"\$FZF_PROMPT\" = 'I> ' ] && echo 'rebind($NORMAL_KEYS)+change-prompt(N> )' || echo abort" \
  --preview="bash '$0' --preview {1}" \
  --preview-window='right,45%,wrap')" || exit 0

chosen="${chosen%%$'\t'*}"
[ -n "$chosen" ] || exit 0

ln -sf "$(basename "$chosen")" "$RESURRECT_DIR/last"
"$PLUGIN_DIR/scripts/restore.sh"

echo
echo "Restored: $(basename "$chosen")"
sleep 1
