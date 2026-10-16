# shellcheck shell=bash
# Shared guard for every menu that types text into a window (vault, snippets, emoji; paste-lib uses it for its wtype
# fallback). The menu runs in its own terminal, so focus can move before the text is typed (the focus restore is best
# effort, a notification or a new window can grab it, the target can close). Rule: type only into the window that was
# focused BEFORE the menu opened; otherwise type nothing, show a notification and let the caller copy instead.
#   tg_active              address of the focused window (empty: none, or not running under Hyprland)
#   tg_record [--here]     the window to type into, call it BEFORE the menu opens: $HUB_TARGET (address:0x..., set by
#                          the hub for run rows, so a hub that did not refocus in time cannot fool the check) unless
#                          --here (menu in the current terminal), else the focused window
#   tg_ok PREV APP         0 when the focused window is PREV; else notify (critical) and return 1. Outside Hyprland
#                          there is no compositor to ask: returns 0 (tests); TG_SKIP=1 does the same explicitly.
tg_active() { hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null; }

tg_in_hypr() { [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null 2>&1; }

tg_record() {
  if [[ ${1:-} != --here && ${HUB_TARGET:-} == address:0x* ]]; then
    printf '%s\n' "${HUB_TARGET#address:}"
  else
    tg_active
  fi
}

tg_ok() {
  local prev=${1:-} app=${2:-menu} cur
  [[ ${TG_SKIP:-0} == 1 ]] && return 0
  tg_in_hypr || return 0
  cur=$(tg_active)
  [[ -n $prev && $cur == "$prev" ]] && return 0
  notify-send -a "$app" -u critical -t 6000 "${app^}" "Focus changed, nothing typed (copy it instead)" 2>/dev/null || true
  return 1
}
