#!/usr/bin/env bash
# pkg-remove: pick explicitly installed packages, remove them with yay -Rns, then offer to move leftovers to Trash.
#   pkg-remove.sh                  fzf multi-select; rows show size, how many packages need it, name
#   pkg-remove.sh --list           the rows (largest first)
#   pkg-remove.sh --leftovers NAME print config/data/cache paths that look like NAME's leftovers
#   pkg-remove.sh [--dry-run] NAME...   remove these names directly
# Leftovers are searched with fd in ~/.config ~/.local/share ~/.cache ~/.local/state and go to the Trash (never rm).
set -u
DRY=0; names=(); mode=pick; left=""
while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;; --list) mode=list ;; --leftovers) mode=left; left=${2:-}; shift ;; *) names+=("$1") ;;
  esac
  shift
done

rows() { # size-in-MiB  required-by-count  name
  LC_ALL=C pacman -Qei 2>/dev/null | awk '
    /^Name/ { name = $3 }
    /^Installed Size/ { sz = $4; u = $5; if (u == "KiB") sz /= 1024; else if (u == "GiB") sz *= 1024; else if (u == "B") sz /= 1048576 }
    /^Required By/ { n = ($4 == "None") ? 0 : NF - 3 }
    /^$/ { if (name != "") printf "%9.1f MiB  req:%-3d %s\n", sz, n, name; name = "" }' | sort -rn
}
leftovers() {
  local n=${1%-bin}; n=${n%-git}
  command -v fd >/dev/null 2>&1 || return 0
  fd -H -d1 -i -- "$n" "$HOME/.config" "$HOME/.local/share" "$HOME/.cache" "$HOME/.local/state" 2>/dev/null
}
case $mode in
  list) rows; exit 0 ;;
  left) leftovers "$left"; exit 0 ;;
esac
command -v yay >/dev/null 2>&1 || { echo "yay not found" >&2; exit 1; }
if ((${#names[@]} == 0)); then
  command -v fzf >/dev/null 2>&1 || { echo "fzf not found" >&2; exit 1; }
  mapfile -t sel < <(rows | fzf -m --reverse --prompt 'remove> ' --header 'size, required-by count, name. Tab: select, Enter: remove' \
    --preview 'pacman -Qi {4}; echo; echo "Required by:"; pactree -r -d1 {4} 2>/dev/null | tail -n +2' --preview-window right:55%:wrap)
  for s in "${sel[@]}"; do names+=("${s##* }"); done
fi
((${#names[@]})) || exit 0
cmd=(yay -Rns "${names[@]}")
if ((DRY)); then
  echo "would run: ${cmd[*]}"
  for n in "${names[@]}"; do echo "leftovers of $n:"; leftovers "$n" | sed 's/^/  /'; done
  exit 0
fi
"${cmd[@]}" || exit $?
for n in "${names[@]}"; do
  mapfile -t found < <(leftovers "$n")
  ((${#found[@]})) || continue
  mapfile -t trash < <(printf '%s\n' "${found[@]}" | fzf -m --reverse --prompt "trash $n> " --header 'leftovers: Tab select, Enter moves to Trash')
  ((${#trash[@]})) && trash-put -- "${trash[@]}"
done
