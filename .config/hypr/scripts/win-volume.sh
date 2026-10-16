#!/usr/bin/env bash
# Per-app volume of the focused window: changes only the PipeWire playback streams that belong to that window's app.
#   win-volume.sh up|down|mute [--addr ADDRESS]    SUPER+XF86AudioRaiseVolume / LowerVolume / Mute, window-menu hooks
#   win-volume.sh --list [--addr ADDRESS]          print the matched clients and sink-input nodes, change nothing
#   --dry-run                                      with up|down|mute: print the wpctl commands instead of running them
#   WIN_VOLUME_STEP=5 (percent), WIN_VOLUME_MAX=1.4 (same 140 % ceiling as the output volume keys)
#
# Matching (research §11.3): a Client belongs to the window when
#   1. its application.process.id is the window pid or one of its descendants (Chromium/Electron play from a child), or
#   2. pipewire.access.portal.app_id equals the window class (flatpak: the reported pid is wrong, Zen shows pid 2), or
#   3. its application.process.binary / application.name equals the class or its last dotted segment (fallback).
# Stream/Output/Audio nodes owned by those clients are the targets.
set -u

STEP=${WIN_VOLUME_STEP:-5}
MAXV=${WIN_VOLUME_MAX:-1.4}
DRY=0
ADDR=""
CMD=""

die() { echo "win-volume: $*" >&2; exit 1; }
note() { notify-send -a win-volume -u low -t 2000 "$@"; }

while (($#)); do
  case $1 in
    up | down | mute | --list) CMD=$1 ;;
    --dry-run) DRY=1 ;;
    --addr) shift; ADDR=${1:-} ;;
    address:* | 0x*) ADDR=$1 ;;
    *) die "usage: win-volume.sh up|down|mute|--list [--addr ADDRESS] [--dry-run]" ;;
  esac
  shift
done
[[ -n $CMD ]] || die "usage: win-volume.sh up|down|mute|--list [--addr ADDRESS] [--dry-run]"

ADDR=${ADDR#address:}
if [[ -n $ADDR ]]; then
  WJ=$(hyprctl clients -j | jq -c --arg a "$ADDR" '.[] | select(.address == $a)')
else
  WJ=$(hyprctl activewindow -j)
fi
[[ -n $WJ ]] || WJ='{}'
CLASS=$(jq -r '.class // ""' <<<"$WJ")
PID=$(jq -r '.pid // 0' <<<"$WJ")
[[ -n $CLASS ]] || { note "App volume" "no focused window"; die "no target window"; }

descendants() {
  local c
  echo "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do descendants "$c"; done
}

# pid <= 2 means a sandbox that hides the real pid (flatpak): never match by pid then
if ((PID > 2)); then
  PIDS=$(descendants "$PID" | jq -Rs 'split("\n") | map(select(length > 0) | tonumber)')
else
  PIDS='[]'
fi

# one line per node: id <TAB> client id <TAB> node description <TAB> app name <TAB> matched-by
MATCHED=$(pw-dump | jq -r --argjson pids "$PIDS" --arg class "$CLASS" '
  ($class | ascii_downcase) as $c
  | ($c | split(".") | last) as $short
  | (map(select(.type == "PipeWire:Interface:Client"))
     | map(. as $cl | ($cl.info.props // {}) as $p
         | (($p["application.process.id"] // -1) | tonumber? // -1) as $pid
         | (($p["pipewire.access.portal.app_id"] // "") | ascii_downcase) as $portal
         | (($p["application.process.binary"] // "") | ascii_downcase) as $bin
         | (($p["application.name"] // "") | ascii_downcase) as $an
         | (if ($pids | index($pid)) != null then "pid"
            elif $portal != "" and $portal == $c then "portal"
            elif ($bin != "" and ($bin == $c or $bin == $short)) or ($an != "" and ($an == $c or $an == $short)) then "name"
            else empty end) as $why
         | {key: ($cl.id | tostring), value: {why: $why, name: ($p["application.name"] // "?")}})
     | from_entries) as $clients
  | .[] | select(.type == "PipeWire:Interface:Node")
  | select(.info.props["media.class"] == "Stream/Output/Audio")
  | ($clients[(.info.props["client.id"] | tostring)]) as $m | select($m != null)
  | [.id, .info.props["client.id"], (.info.props["media.name"] // .info.props["node.name"] // "?"), $m.name, $m.why] | @tsv')

if [[ $CMD == --list ]]; then
  echo "window: class=$CLASS pid=$PID descendants=$(jq -c . <<<"$PIDS")"
  if [[ -z $MATCHED ]]; then echo "no audio stream for $CLASS"; exit 0; fi
  printf 'node\tclient\tmedia\tapp\tmatched-by\n%s\n' "$MATCHED"
  while IFS=$'\t' read -r id _; do
    printf 'node %s: %s\n' "$id" "$(wpctl get-volume "$id" 2>&1)"
  done <<<"$MATCHED"
  exit 0
fi

if [[ -z $MATCHED ]]; then
  note "App volume" "no audio stream for $CLASS"
  echo "no audio stream for $CLASS" >&2
  exit 1
fi

mapfile -t IDS < <(cut -f1 <<<"$MATCHED")
APP=$(head -n1 <<<"$MATCHED" | cut -f4)

run() { if ((DRY)); then echo "$*"; else "$@" >/dev/null; fi; }

case $CMD in
  up) for id in "${IDS[@]}"; do run wpctl set-volume -l "$MAXV" "$id" "${STEP}%+"; done ;;
  down) for id in "${IDS[@]}"; do run wpctl set-volume "$id" "${STEP}%-"; done ;;
  mute)
    # any stream still audible -> mute all of them, otherwise unmute all
    target=0
    for id in "${IDS[@]}"; do
      wpctl get-volume "$id" 2>/dev/null | grep -q MUTED || target=1
    done
    for id in "${IDS[@]}"; do run wpctl set-mute "$id" "$target"; done
    ;;
esac

if ((DRY)); then
  echo "# matched nodes: ${IDS[*]} (app: $APP)"
  exit 0
fi

# feedback: highest stream volume, "muted" if every stream is muted
maxvol=0
muted=1
for id in "${IDS[@]}"; do
  out=$(wpctl get-volume "$id" 2>/dev/null) || continue
  grep -q MUTED <<<"$out" || muted=0
  v=$(awk '{printf "%d", $2 * 100 + 0.5}' <<<"$out")
  ((v > maxvol)) && maxvol=$v
done

if ((muted)); then
  text="$APP muted"
  icon=audio-volume-muted
  frac=0
else
  text="$APP $maxvol%"
  icon=audio-volume-high
  frac=$(awk -v v="$maxvol" 'BEGIN { f = v / 100; if (f > 1) f = 1; printf "%.2f", f }')
fi
swayosd-client --custom-progress "$frac" --custom-progress-text "$text" --custom-icon "$icon" 2>/dev/null \
  || notify-send -a win-volume -t 1500 -h string:x-dunst-stack-tag:win-volume -h "int:value:$maxvol" "App volume" "$text"
