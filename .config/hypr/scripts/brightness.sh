#!/usr/bin/env bash
# brightness: brightness keys that follow the focused monitor.
#
#   brightness.sh up|down [--dry-run]
#
# The laptop panel (eDP-*) keeps swayosd / brightnessctl exactly as before. Any other monitor is driven over DDC/CI
# with ddcutil (`setvcp 10`): the monitor -> I2C bus map is detected once and cached, the new value is shown at
# once (swayosd custom progress, dunst fallback) and written to the monitor in a background worker, so held keys
# stay snappy. Needs ddcutil and access to /dev/i2c-* (group i2c; log in again after the root script added it).
set -u

STEP="${BRIGHTNESS_STEP:-10}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/brightness-ddc"
RUN_DIR="${XDG_RUNTIME_DIR:-/tmp}/brightness-ddc"
DRY=0
DIR=""
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    up | down) DIR=$a ;;
  esac
done
[[ -n $DIR ]] || { echo "usage: brightness.sh up|down [--dry-run]" >&2; exit 2; }

note() { notify-send -a brightness -h string:x-dunst-stack-tag:brightness-ddc -t 2500 "$@" 2>/dev/null || true; }
osd() { # osd FRACTION TEXT
  swayosd-client --custom-progress "$1" --custom-progress-text "$2" --custom-icon display-brightness-symbolic 2>/dev/null \
    || notify-send -a brightness -t 1500 -h string:x-dunst-stack-tag:brightness-ddc -h "int:value:$3" "Brightness" "$2" 2>/dev/null || true
}

focused=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused) | .name' 2>/dev/null | head -1)
focused=${focused:-eDP-1}

if [[ $focused == eDP-* ]]; then
  if [[ $DIR == up ]]; then
    cmd=(swayosd-client --brightness raise)
    fallback=(brightnessctl set "+${STEP}%")
  else
    cmd=(swayosd-client --brightness lower)
    fallback=(brightnessctl set "${STEP}%-")
  fi
  if ((DRY)); then echo "panel $focused: ${cmd[*]} || ${fallback[*]}"; exit 0; fi
  "${cmd[@]}" 2>/dev/null || "${fallback[@]}"
  exit 0
fi

# ── external monitor over DDC/CI ────────────────────────────────────────────────
if ! command -v ddcutil >/dev/null 2>&1; then
  ((DRY)) && { echo "external $focused: ddcutil not installed (sudo ~/dotfiles/apply-system.sh --only install)"; exit 0; }
  note -u normal "External brightness" "ddcutil is not installed (run the root script)"
  exit 0
fi

mkdir -p "$CACHE_DIR" "$RUN_DIR"
BUSMAP="$CACHE_DIR/buses.tsv"   # monitor<TAB>bus number

detect_buses() { # ddcutil detect --brief -> "connector<TAB>bus" lines (connector like HDMI-A-1)
  ddcutil detect --brief 2>/dev/null | awk '
    /^Display/ { bus = ""; conn = "" }
    /I2C bus:/ { n = $NF; sub(/.*i2c-/, "", n); bus = n }
    /DRM_connector:|DRM connector:/ { c = $NF; sub(/^card[0-9]+-/, "", c); conn = c }
    bus != "" && conn != "" { print conn "\t" bus; bus = ""; conn = "" }'
}

bus_for() { # cached lookup, re-detected when missing or the node vanished
  local b
  b=$(awk -F'\t' -v m="$1" '$1 == m { print $2 }' "$BUSMAP" 2>/dev/null | head -1)
  if [[ -n $b && -e /dev/i2c-$b ]]; then echo "$b"; return 0; fi
  detect_buses >"$BUSMAP.new" 2>/dev/null
  if [[ -s $BUSMAP.new ]]; then mv -f "$BUSMAP.new" "$BUSMAP"; else rm -f "$BUSMAP.new"; fi
  awk -F'\t' -v m="$1" '$1 == m { print $2 }' "$BUSMAP" 2>/dev/null | head -1
}

if ((DRY)); then
  bus=$(bus_for "$focused")
  echo "external $focused: bus=${bus:-unknown} step=$STEP% -> ddcutil --bus ${bus:-?} --noverify setvcp 10 <value>"
  exit 0
fi

bus=$(bus_for "$focused")
if [[ -z $bus ]]; then
  note "External brightness" "$focused has no DDC/CI bus (no access to /dev/i2c-*? log in again after joining group i2c, or the monitor does not support DDC)"
  exit 0
fi

want="$RUN_DIR/$focused.want"   # value we want on the monitor
done_f="$RUN_DIR/$focused.done" # value last written
if [[ -r $want ]]; then
  cur=$(cat "$want")
else
  # first use since login: read the real value ("VCP 10 C <cur> <max>")
  read -r cur max < <(ddcutil --bus "$bus" getvcp 10 --brief 2>/dev/null | awk '$1 == "VCP" && $3 == "C" { print $4, $5 }')
  if [[ -z ${cur:-} ]]; then
    note "External brightness" "could not read brightness of $focused (DDC/CI disabled in the monitor menu?)"
    exit 0
  fi
  echo "${max:-100}" >"$RUN_DIR/$focused.max"
fi
max=$(cat "$RUN_DIR/$focused.max" 2>/dev/null || echo 100)
[[ $cur =~ ^[0-9]+$ ]] || cur=50
if [[ $DIR == up ]]; then new=$((cur + STEP)); else new=$((cur - STEP)); fi
((new > max)) && new=$max
((new < 0)) && new=0
echo "$new" >"$want"

pct=$((new * 100 / (max > 0 ? max : 100)))
osd "$(awk -v p="$pct" 'BEGIN { printf "%.2f", p / 100 }')" "$focused ${pct}%" "$pct"

# one worker at a time; it keeps writing until the monitor matches the latest wanted value
(
  flock -n 9 || exit 0
  while :; do
    w=$(cat "$want" 2>/dev/null) || exit 0
    [[ $w == "$(cat "$done_f" 2>/dev/null)" ]] && exit 0
    if ddcutil --bus "$bus" --noverify setvcp 10 "$w" >/dev/null 2>&1; then
      echo "$w" >"$done_f"
    else
      sleep 0.5
      ddcutil --bus "$bus" --noverify setvcp 10 "$w" >/dev/null 2>&1 && echo "$w" >"$done_f" || exit 0
    fi
  done
) 9>"$RUN_DIR/$focused.lock" >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
