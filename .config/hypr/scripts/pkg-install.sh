#!/usr/bin/env bash
# pkg-install: fuzzy install of repo + AUR packages with yay (Omarchy-style fzf picker; the idea is MIT).
#   pkg-install.sh                 fzf multi-select (Tab), preview = yay -Si, Enter installs
#   pkg-install.sh --list          "repo/name version" rows (installed ones marked)
#   pkg-install.sh [--dry-run] NAME...   install these names directly
set -u
DRY=0; names=(); mode=pick
for a in "$@"; do
  case $a in --dry-run) DRY=1 ;; --list) mode=list ;; *) names+=("$a") ;; esac
done
rows() { yay -Sl 2>/dev/null | awk '{ printf "%s/%s %s%s\n", $1, $2, $3, ($NF == "[installed]" ? " [installed]" : "") }'; }
[[ $mode == list ]] && { rows; exit 0; }
command -v yay >/dev/null 2>&1 || { echo "yay not found" >&2; exit 1; }
if ((${#names[@]} == 0)); then
  command -v fzf >/dev/null 2>&1 || { echo "fzf not found" >&2; exit 1; }
  mapfile -t sel < <(rows | fzf -m --reverse --prompt 'install> ' --header 'Tab: select, Enter: install' \
    --preview 'yay -Si {1} 2>/dev/null | head -40' --preview-window right:60%:wrap)
  for s in "${sel[@]}"; do names+=("${s%% *}"); done
fi
((${#names[@]})) || exit 0
cmd=(yay -S --needed "${names[@]}")
if ((DRY)); then echo "would run: ${cmd[*]}"; exit 0; fi
"${cmd[@]}"
