#!/usr/bin/env bash
# Toggle a gpu-screen-recorder recording. SUPER+R: focused monitor, SUPER+SHIFT+R: region, SUPER+ALT+R: monitor + mic.
# Usage: rec-toggle.sh [monitor | region | window [ADDRESS] | stop] [--mic] [--dry-run]
#   monitor (default)  the focused monitor
#   region             slurp selection
#   window [ADDRESS]   that window's rectangle, default the active one
#   stop               stop a running recording, never start one
#   --mic              also record the default microphone; each -a is its own audio track:
#                      track 1 = default output (system sound), track 2 = default input (mic)
#   --dry-run          print the gpu-screen-recorder command line instead of recording (also for stop)
# A running recording is stopped by any invocation except --dry-run.
# Output: ~/Videos/screencaptures/<date>.mp4. Waybar can test for a recording with
# `pgrep -x gpu-screen-reco` (the kernel truncates the process name to 15 chars);
# the recording flavour (mic or not) is left in $XDG_RUNTIME_DIR/rec-mic and the pid plus start time in
# $XDG_RUNTIME_DIR/rec-pid for the waybar module.
set -u

proc=gpu-screen-reco
outdir="$HOME/Videos/screencaptures"
micflag="${XDG_RUNTIME_DIR:-/tmp}/rec-mic"
pidfile="${XDG_RUNTIME_DIR:-/tmp}/rec-pid"   # "<pid> <start epoch>", read by the waybar recording module (elapsed time)

mode=monitor
addr=""
mic=0
dry=0
for a in "$@"; do
  case $a in
    monitor | region | window | stop) mode=$a ;;
    --mic) mic=1 ;;
    --dry-run) dry=1 ;;
    *) addr=$a ;;
  esac
done

if ((dry)); then
  echo "recording mode=$mode mic=$mic running=$(pgrep -x "$proc" >/dev/null && echo yes || echo no)"
fi

if [[ $mode == stop ]] && ! pgrep -x "$proc" >/dev/null; then
  ((dry)) || notify-send -a recorder -t 2000 "Recording" "nothing is being recorded"
  exit 0
fi

if ((!dry)) && pgrep -x "$proc" >/dev/null; then
  pkill -SIGINT -x "$proc"
  # let the encoder flush the file before announcing it
  for _ in {1..50}; do
    pgrep -x "$proc" >/dev/null || break
    sleep 0.1
  done
  rm -f "$micflag" "$pidfile"
  notify-send -a recorder -t 2500 "Recording saved" "$outdir"
  exit 0
fi

mkdir -p "$outdir"
out="$outdir/$(date +%F_%H-%M-%S).mp4"

monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
[[ -n $monitor ]] || { notify-send -a recorder -u critical "Recording failed" "no focused monitor"; exit 1; }

if [[ $mode == region ]]; then
  # slurp returns logical pixels; gpu-screen-recorder wants pixels of the captured output
  geo=$(slurp -f '%x %y %w %h') || exit 0
  read -r x y w h <<<"$geo"
  read -r mx my scale <<<"$(hyprctl monitors -j | jq -r '.[] | select(.focused) | "\(.x) \(.y) \(.scale)"')"
  region=$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v mx="$mx" -v my="$my" -v s="$scale" \
    'BEGIN { printf "%dx%d+%d+%d", w * s, h * s, (x - mx) * s, (y - my) * s }')
  args=(-w region -region "$region")
elif [[ $mode == window ]]; then
  addr=${addr#address:}
  if [[ -n $addr ]]; then
    wj=$(hyprctl clients -j | jq -c --arg a "$addr" '.[] | select(.address == $a)')
  else
    wj=$(hyprctl activewindow -j)
  fi
  [[ -n $wj ]] || { notify-send -a recorder -u critical "Recording failed" "no such window"; exit 1; }
  # window at/size and monitor x/y are logical; scale to the captured output's pixels (x, y relative to the monitor)
  region=$(hyprctl monitors -j | jq -r --argjson w "$wj" '.[] | select(.id == $w.monitor)
    | "\((($w.size[0]) * .scale) | floor)x\((($w.size[1]) * .scale) | floor)+\((($w.at[0] - .x) * .scale) | floor)+\((($w.at[1] - .y) * .scale) | floor)"')
  [[ -n $region ]] || { notify-send -a recorder -u critical "Recording failed" "window is not on a monitor"; exit 1; }
  args=(-w region -region "$region")
else
  args=(-w "$monitor")
fi

audio=(-a default_output)
((mic)) && audio+=(-a default_input)

if ((dry)); then
  echo "gpu-screen-recorder ${args[*]} -f 60 ${audio[*]} -o $out"
  exit 0
fi

if ((mic)); then : >"$micflag"; else rm -f "$micflag"; fi
gpu-screen-recorder "${args[@]}" -f 60 "${audio[@]}" -o "$out" &
printf '%s %s\n' "$!" "$(date +%s)" >"$pidfile"
disown
if ((mic)); then
  notify-send -a recorder -t 2500 "Recording (system + mic)" "$out"
else
  notify-send -a recorder -t 2500 "Recording" "$out"
fi
