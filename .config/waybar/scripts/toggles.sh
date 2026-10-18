#!/usr/bin/env bash
# toggles: the switch modules of the waybar "toggles" drawer and the one-glyph summary of the enabled switches.
#   toggles.sh summary-raw         the same JSON as summary (full variant), probed now; summary caches it through cache.sh
#   toggles.sh summary [--alert]   JSON: glyphs of every enabled switch (class enabled). Nothing enabled: the leader shows a
#                                  dim "all off" glyph; with --alert (compact bar) the text is empty
#   toggles.sh switch NAME         JSON for one child: on = glyph + class enabled, off = glyph + class dim
#   toggles.sh toggle NAME         flip it, then refresh the bar (signal 8)
#   toggles.sh state NAME          exit 0 when NAME is on (used by the hub)
#   NAME is one of: dnd caffeine awake lid night vpn ns tgsend (tgsend only exists while the tgconfirm broker runs: Telegram sending;
#   ns = microphone noise suppression, only exists with EasyEffects and the ee-ctl helper)
# ns is the one switch whose NORMAL state is on: the summary shows it only when it is off or the chain is broken (class warning),
# never as an "enabled" switch, so a healthy machine still reads "all off".
# (the power profile child is hypr/scripts/power-profile.sh waybar; a profile other than balanced counts as enabled)
# Colour classes: normal | dim | enabled | warning | critical (waybar/style.css maps them to palette tokens).
set -u

SCRIPTS="$HOME/.config/hypr/scripts"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMES=(dnd caffeine awake lid night vpn ns tgsend power)
G_OFF='󰨙'
G_DND_ON='󰂛' G_DND_OFF='󰂜'
G_CAF_ON='󰅶' G_CAF_OFF='󰛊'
G_AWK_ON='󰒳' G_AWK_OFF='󰒲'
G_LID_ON='󰌢' G_LID_OFF='󰛧'
G_NIT_ON='󰖔' G_NIT_OFF='󰖔'
G_VPN_ON='󰦝' G_VPN_OFF='󰦜'
G_TGS_ON='󰒊' G_TGS_OFF='󰒊'
G_NS_ON='󰍬' G_NS_OFF='󰍭'
G_SAVER='󰌪' G_PERF='󰓅'

poke_bar() { rm -f "${XDG_RUNTIME_DIR:-/tmp}/waybar-cache/toggles.json"; pkill -o -u "$UID" -RTMIN+8 -x waybar 2>/dev/null || true; }

# login_age: seconds since the Hyprland instance of this session started (test hook TOGGLES_LOGIN_AGE); a huge number without one
login_age() {
  [[ -n ${TOGGLES_LOGIN_AGE:-} ]] && { echo "$TOGGLES_LOGIN_AGE"; return; }
  local d="${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-none}" t
  t=$(stat -c %Y "$d" 2>/dev/null) || { echo 999999; return; }
  echo $(($(date +%s) - t))
}

# probe NAME: sets ON (0/1), GLYPH_ON, GLYPH_OFF, LABEL, DETAIL (short text), TEXT_ON (what the summary shows), HINT
probe() {
  local d
  ON=0 DETAIL="" HINT="" STATE_TEXT="" WARN=0 SUMMARY_ON=1
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
    ns)
      # noise suppression: ee-ctl ns status (exit 0 = EasyEffects answers, rnnoise active, global bypass off); no ee-ctl or no
      # EasyEffects = switch hidden. Normal state = on, so the summary lists it only as a warning (off or EasyEffects not running).
      GLYPH_ON=$G_NS_ON GLYPH_OFF=$G_NS_OFF LABEL="Noise suppression (EasyEffects)" SUMMARY_ON=0
      [[ -x $HOME/.local/bin/ee-ctl && -x ${TOGGLES_EE_BIN:-/usr/bin/easyeffects} ]] || return 1
      local ns
      ns=$("$HOME/.local/bin/ee-ctl" ns status 2>/dev/null)
      if [[ $ns == on ]]; then
        ON=1
        d=$(pactl get-default-source 2>/dev/null)
        d=$(pactl --format=json list sources 2>/dev/null | jq -r --arg n "$d" '.[] | select(.name == $n) | .description' 2>/dev/null)
        DETAIL="${d:-microphone}"
      elif [[ $ns != off && $(login_age) -lt ${TOGGLES_NS_GRACE:-60} ]]; then
        # EasyEffects starts a few seconds after the session (audio-ensure --boot heals the cards first): no warning glyph yet
        STATE_TEXT="EasyEffects is starting"
      else
        WARN=1 TEXT_WARN=$GLYPH_OFF
        [[ -n $("$HOME/.local/bin/ee-ctl" socket 2>/dev/null) ]] || STATE_TEXT="EasyEffects is not running"
      fi
      HINT="L: toggle" ;;
    tgsend)
      # Telegram sending (mcp-telegram-send): the broker's world-readable state file; no state file = no broker = switch hidden
      GLYPH_ON=$G_TGS_ON GLYPH_OFF=$G_TGS_OFF LABEL="Telegram sending (AI may ask)"
      local st=${MCP_TGSEND_STATE:-/run/tgconfirm/state.json} left
      [[ -r $st ]] || return 1
      left=$(jq -r 'if .enabled and (.until > now) then ((.until - now + 59) / 60 | floor) else empty end' "$st" 2>/dev/null)
      if [[ -n $left ]]; then ON=1 DETAIL="${left} min left, every message needs the popup"; fi
      TEXT_ON="$GLYPH_ON${left:+ ${left}m}"
      HINT="L: toggle (needs the popup)" ;;
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

# summary [--alert]: both bars (compact --alert, full leader) tick every 10 s, so the probes run once for the two through
# cache.sh (TTL 8 s, entry `toggles`); every toggle action drops the entry before it pokes signal 8. The compact variant
# is derived from the cached full JSON: "all off" is the only state with class dim, and it prints an empty text there.
summary() {
  local out
  out=$("$HERE/cache.sh" toggles 8 -- "${BASH_SOURCE[0]}" summary-raw) || out=""
  [[ -n $out ]] || out=$(summary_raw)
  if [[ ${1:-} == --alert && $out == *'"class":"dim"'* ]]; then echo '{"text":""}'; else echo "$out"; fi
}

summary_raw() { # the full-bar JSON, probed now
  local n on=() warn=() lines=() text
  for n in "${NAMES[@]}"; do
    probe "$n" || continue
    ((ON && SUMMARY_ON)) && on+=("$TEXT_ON")
    ((WARN)) && warn+=("$TEXT_WARN")
    lines+=("$(state_line)")
  done
  if ((${#on[@]} == 0 && ${#warn[@]} == 0)); then
    json "$G_OFF" dim "Toggles: all off"$'\n'"$(printf '%s\n' "${lines[@]}")"$'\n\nL: toggles menu'
    return 0
  fi
  text="${on[*]}${on[*]:+ }${warn[*]}"
  text=${text% }
  if ((${#warn[@]})); then
    json "$text" warning "Toggles: ${#on[@]} on, ${#warn[@]} need attention"$'\n'"$(printf '%s\n' "${lines[@]}")"$'\n\nL: toggles menu'
  else
    json "$text" enabled "Toggles: ${#on[@]} on"$'\n'"$(printf '%s\n' "${lines[@]}")"$'\n\nL: toggles menu'
  fi
}

switch() {
  probe "${1:-}"
  case $? in
    0) ;;
    1) echo '{"text":""}'; return 0 ;;   # a switch that does not exist on this machine (tgsend without the broker)
    *) return 2 ;;
  esac
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
    ns) "$HOME/.local/bin/ee-ctl" ns toggle ;;   # it notifies once and pokes the bar itself
    tgsend) setsid -f "$HOME/.local/bin/mcp-telegram-send" toggle >/dev/null 2>&1 </dev/null ;;   # it pokes the bar itself when the popup is answered
    *) echo "toggles.sh: unknown switch '${1:-}' (dnd caffeine awake lid night vpn ns tgsend)" >&2; return 2 ;;
  esac
  poke_bar
}

case ${1:-} in
  summary) shift; summary "$@" ;;
  summary-raw) summary_raw ;;
  switch) shift; switch "${1:-}" ;;
  toggle) shift; toggle "${1:-}" ;;
  state) shift; probe "${1:-}" && ((ON)) ;;
  *) echo "usage: toggles.sh summary [--alert] | switch NAME | toggle NAME | state NAME" >&2; exit 2 ;;
esac
