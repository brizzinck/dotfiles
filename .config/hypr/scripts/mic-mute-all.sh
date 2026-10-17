#!/usr/bin/env bash
# Mute or unmute every microphone (all PipeWire Audio/Source nodes, not just the default one).
#   mic-mute-all.sh             SUPER+SHIFT+M: if any microphone is live, mute all; otherwise unmute the default one
#   mic-mute-all.sh status      print each source and its mute state; exit 0 when every microphone is muted. Always silent
#                               (hub toggle row, waybar): no microphone at all prints nothing and exits 1; only a real toggle notifies
#   --dry-run                   print the wpctl commands instead of running them
# The waybar module (pulseaudio#mic) shows the DEFAULT source, and muting all always includes it, so the bar
# reflects the change. A source that appears later (hot-plugged mic) starts unmuted; press the key again.
set -u

DRY=0
CMD=toggle
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    status | toggle) CMD=$a ;;
    *) echo "usage: mic-mute-all.sh [status] [--dry-run]" >&2; exit 2 ;;
  esac
done

mapfile -t SOURCES < <(pw-dump | jq -r '.[] | select(.type == "PipeWire:Interface:Node")
  | select(.info.props["media.class"] == "Audio/Source")
  | "\(.id)\t\(.info.props["node.description"] // .info.props["node.name"])"')
if ((${#SOURCES[@]} == 0)); then
  [[ $CMD == status ]] || notify-send -a mic -u low "Microphones" "no microphone found"
  exit 1
fi

live=0
for s in "${SOURCES[@]}"; do
  id=${s%%$'\t'*}
  state=live
  if wpctl get-volume "$id" 2>/dev/null | grep -q MUTED; then state=muted; else live=1; fi
  [[ $CMD == status ]] && printf '%s\t%s\t%s\n' "$id" "$state" "${s#*$'\t'}"
done
if [[ $CMD == status ]]; then ((live)) && exit 1 || exit 0; fi

run() { if ((DRY)); then echo "$*"; else "$@" >/dev/null; fi; }

if ((live)); then
  for s in "${SOURCES[@]}"; do run wpctl set-mute "${s%%$'\t'*}" 1; done
  text="all microphones muted"
  icon=microphone-sensitivity-muted
else
  run wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0
  text="default microphone live"
  icon=microphone-sensitivity-high
fi
((DRY)) && exit 0
swayosd-client --custom-message "$text" --custom-icon "$icon" 2>/dev/null \
  || notify-send -a mic -t 1500 -h string:x-dunst-stack-tag:mic "Microphone" "$text"
