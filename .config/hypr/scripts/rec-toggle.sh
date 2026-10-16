#!/usr/bin/env bash
# Toggle a gpu-screen-recorder recording. SUPER+R: focused monitor, SUPER+SHIFT+R: region.
# Usage: rec-toggle.sh [region | window [ADDRESS]]   (window: that window's rectangle, default the active one)
# Output: ~/Videos/screencaptures/<date>.mp4. Waybar can test for a recording with
# `pgrep -x gpu-screen-reco` (the kernel truncates the process name to 15 chars).
set -u

proc=gpu-screen-reco
outdir="$HOME/Videos/screencaptures"

if pgrep -x "$proc" >/dev/null; then
  pkill -SIGINT -x "$proc"
  # let the encoder flush the file before announcing it
  for _ in {1..50}; do
    pgrep -x "$proc" >/dev/null || break
    sleep 0.1
  done
  notify-send -a recorder -t 2500 "Recording saved" "$outdir"
  exit 0
fi

mkdir -p "$outdir"
out="$outdir/$(date +%F_%H-%M-%S).mp4"

monitor=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .name')
[[ -n $monitor ]] || { notify-send -a recorder -u critical "Recording failed" "no focused monitor"; exit 1; }

if [[ ${1:-} == region ]]; then
  # slurp returns logical pixels; gpu-screen-recorder wants pixels of the captured output
  geo=$(slurp -f '%x %y %w %h') || exit 0
  read -r x y w h <<<"$geo"
  read -r mx my scale <<<"$(hyprctl monitors -j | jq -r '.[] | select(.focused) | "\(.x) \(.y) \(.scale)"')"
  region=$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v mx="$mx" -v my="$my" -v s="$scale" \
    'BEGIN { printf "%dx%d+%d+%d", w * s, h * s, (x - mx) * s, (y - my) * s }')
  args=(-w region -region "$region")
elif [[ ${1:-} == window ]]; then
  addr=${2:-}
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

gpu-screen-recorder "${args[@]}" -f 60 -a default_output -o "$out" &
disown
notify-send -a recorder -t 2500 "Recording" "$out"
