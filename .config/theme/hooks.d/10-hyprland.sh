#!/usr/bin/env bash
# Hyprland: re-read the colour fragment of the variant (hyprland.conf sources ~/.local/state/theme/current/hyprland.conf).
# Hyprland watches hyprland.conf and its sourced files, but not the flip of the `current` link, so reload explicitly,
# and only when the live colours differ from the variant. Afterwards `hyprctl configerrors` must be empty.
set -u
command -v hyprctl >/dev/null 2>&1 || exit 0

# A shell started before the last login (tmux pane, cron) may carry a stale instance signature: pick the live one.
if ! hyprctl version >/dev/null 2>&1; then
  newest=
  for lock in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/hypr/*/hyprland.lock; do
    [[ -e $lock ]] || continue
    [[ -z $newest || $lock -nt $newest ]] && newest=$lock
  done
  [[ -n $newest ]] || exit 0
  sig=$(basename "$(dirname "$newest")")
  export HYPRLAND_INSTANCE_SIGNATURE=$sig
  hyprctl version >/dev/null 2>&1 || exit 0
fi

dir=${THEME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/theme/current}
want=$(sed -n 's/.*"line": "#\([0-9a-fA-F]\{6\}\)".*/\1/p' "$dir/tokens.json" 2>/dev/null | head -1)
have=$(hyprctl getoption general:col.inactive_border 2>/dev/null | awk '/custom type/ {print substr($3, 3)}')
if [[ -n $want && $want == "$have" ]]; then
  echo "hyprland: already on ${THEME_VARIANT:-the variant}"
else
  hyprctl reload >/dev/null || { echo "hyprland: reload failed" >&2; exit 1; }
  echo "hyprland: reloaded"
fi

errs=$(hyprctl configerrors 2>/dev/null)
if [[ -n $errs ]]; then
  printf 'hyprland: config errors after reload:\n%s\n' "$errs" >&2
  exit 1
fi
