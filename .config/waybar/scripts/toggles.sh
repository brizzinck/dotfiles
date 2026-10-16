#!/usr/bin/env bash
# toggles: the switch modules of the waybar "toggles" drawer and the one-glyph summary of the enabled switches.
#   toggles.sh summary [--alert]   JSON: glyphs of every enabled switch (class enabled). Nothing enabled: the leader shows a
#                                  dim "all off" glyph; with --alert (compact bar) the text is empty
#   toggles.sh switch NAME         JSON for one child: on = glyph + class enabled, off = glyph + class dim
#   toggles.sh toggle NAME         flip it, then refresh the bar (signal 8)
#   toggles.sh state NAME          exit 0 when NAME is on (used by the hub)
#   NAME is one of: dnd caffeine awake lid night vpn
# (the power profile child is hypr/scripts/power-profile.sh waybar; a profile other than balanced counts as enabled)
# Colour classes: normal | dim | enabled | warning | critical (waybar/style.css maps them to palette tokens).
set -u

SCRIPTS="$HOME/.config/hypr/scripts"
NAMES=(dnd caffeine awake lid night vpn power)
G_OFF='󰨙'
G_DND_ON='󰂛' G_DND_OFF='󰂜'
G_CAF_ON='󰅶' G_CAF_OFF='󰛊'
G_AWK_ON='󰒳' G_AWK_OFF='󰒲'
G_LID_ON='󰌢' G_LID_OFF='󰛧'
G_NIT_ON='󰖔' G_NIT_OFF='󰖔'
G_VPN_ON='󰦝' G_VPN_OFF='󰦜'
G_SAVER='󰌪' G_PERF='󰓅'

poke_bar() { pkill -o -u "$UID" -RTMIN+8 -x waybar 2>/dev/null || true; }

# probe NAME: sets ON (0/1), GLYPH_ON, GLYPH_OFF, LABEL, DETAIL (short text), TEXT_ON (what the summary shows), HINT
probe() {
  local d
  ON=0 DETAIL="" HINT="" STATE_TEXT=""
  case $1 in
    dnd)
      GLYPH_ON=$G_DND_ON GLYPH_OFF=$G_DND_OFF LABEL="Do not disturb"
      if [[ $(dunstctl is-paused 2>/dev/null) == true ]]; then
        ON=1 d=$(dunstctl count waiting 2>/dev/null)
        DETAIL="${d:-0} waiting"
      fi
      TEXT_ON="$GLYPH_ON${d:+ $d}"
      HINT="L: toggle · R: notification history" ;;
    caffeine)
      GLYPH_ON=$G_CAF_ON GLYPH_OFF=$G_CAF_OFF LABEL="Caffeine (idle handling stopped)"
      pgrep -x hypridle >/dev/null || ON=1
      DETAIL="no dim, screensaver or panel-off"
      TEXT_ON=$GLYPH_ON
      HINT="L: toggle" ;;
    awake)
      GLYPH_ON=$G_AWK_ON GLYPH_OFF=$G_AWK_OFF LABEL="Keep awake"
      d=$("$SCRIPTS/keep-awake.sh" status 2>/dev/null) && ON=1
      DETAIL=${d#on }
      TEXT_ON=$GLYPH_ON
      if [[ $d =~ \(left\ ([0-9hm]+)\) ]]; then TEXT_ON="$GLYPH_ON ${BASH_REMATCH[1]}"; fi
      HINT="L: toggle · R: choose duration" ;;
    lid)
      GLYPH_ON=$G_LID_ON GLYPH_OFF=$G_LID_OFF LABEL="Keep working with the lid closed"
      "$SCRIPTS/lid.sh" status >/dev/null 2>&1 && ON=1
      DETAIL="closing the lid does not suspend"
      TEXT_ON=$GLYPH_ON
      HINT="L: toggle" ;;
    night)
      GLYPH_ON=$G_NIT_ON GLYPH_OFF=$G_NIT_OFF LABEL="Night light"
      pgrep -x hyprsunset >/dev/null && ON=1
      DETAIL="hyprsunset 4500 K"
      TEXT_ON=$GLYPH_ON
      HINT="L: toggle" ;;
    vpn)
      GLYPH_ON=$G_VPN_ON GLYPH_OFF=$G_VPN_OFF LABEL="VPN"
      d=$(ip -br link 2>/dev/null |
        awk '$1 ~ /^(tun|tap|wg|tailscale|pritunl|surfshark|proton|nordlynx|utun)/ && ($2 == "UP" || $2 == "UNKNOWN") {print $1}' | paste -sd' ')
      [[ -n $d ]] && { ON=1; DETAIL=$d; }
      TEXT_ON=$GLYPH_ON
      HINT="L: VPN picker" ;;
    power)
      d=$("$SCRIPTS/power-profile.sh" get 2>/dev/null) || d=balanced
      LABEL="Power profile" DETAIL=$d
      case $d in
        power-saver) ON=1 GLYPH_ON=$G_SAVER ;;
        performance) ON=1 GLYPH_ON=$G_PERF ;;
        *) GLYPH_ON=$G_SAVER ;;
      esac
      GLYPH_OFF=$GLYPH_ON TEXT_ON=$GLYPH_ON STATE_TEXT=$d
      HINT="L: next profile · R: choose" ;;
    *) echo "toggles.sh: unknown switch '$1' (${NAMES[*]})" >&2; return 2 ;;
  esac
}

# one tooltip line: "Label: on (detail)" / "Label: off" / "Label: <state text>"
state_line() {
  if [[ -n $STATE_TEXT ]]; then printf '%s: %s' "$LABEL" "$STATE_TEXT"
  elif ((ON)); then printf '%s: on%s' "$LABEL" "${DETAIL:+ ($DETAIL)}"
  else printf '%s: off' "$LABEL"; fi
}

json() { # json TEXT CLASS TOOLTIP
  jq -cn --arg t "$1" --arg c "$2" --arg tip "$3" '{text: $t, class: $c, tooltip: $tip}'
}

summary() {
  local alert=0 n on=() lines=() text
  [[ ${1:-} == --alert ]] && alert=1
  for n in "${NAMES[@]}"; do
    probe "$n" || continue
    ((ON)) && on+=("$TEXT_ON")
    lines+=("$(state_line)")
  done
  if ((${#on[@]} == 0)); then
    ((alert)) && { echo '{"text":""}'; return 0; }
    json "$G_OFF" dim "Toggles: all off"$'\n'"$(printf '%s\n' "${lines[@]}")"$'\n\nL: toggles menu'
    return 0
  fi
  text="${on[*]}"
  json "$text" enabled "Toggles: ${#on[@]} on"$'\n'"$(printf '%s\n' "${lines[@]}")"$'\n\nL: toggles menu'
}

switch() {
  probe "${1:-}" || return 2
  if ((ON)); then
    json "$GLYPH_ON" enabled "$(state_line)"$'\n\n'"$HINT"
  else
    json "$GLYPH_OFF" dim "$(state_line)"$'\n\n'"$HINT"
  fi
}

toggle() {
  case ${1:-} in
    dnd) dunstctl set-paused toggle ;;
    caffeine) "$SCRIPTS/idle-toggle.sh" ;;
    awake) "$SCRIPTS/keep-awake.sh" toggle ;;
    lid) "$SCRIPTS/lid.sh" toggle ;;
    night) if pgrep -x hyprsunset >/dev/null; then pkill -x hyprsunset; else setsid -f hyprsunset -t 4500 >/dev/null 2>&1; fi ;;
    vpn) ghostty --class=float.tui -e zsh -ic vpn ;;
    *) echo "toggles.sh: unknown switch '${1:-}' (dnd caffeine awake lid night vpn)" >&2; return 2 ;;
  esac
  poke_bar
}

case ${1:-} in
  summary) shift; summary "$@" ;;
  switch) shift; switch "${1:-}" ;;
  toggle) shift; toggle "${1:-}" ;;
  state) shift; probe "${1:-}" && ((ON)) ;;
  *) echo "usage: toggles.sh summary [--alert] | switch NAME | toggle NAME | state NAME" >&2; exit 2 ;;
esac
