#!/usr/bin/env bash
# Keybind cheatsheet from the live bind table (descriptions come from `bindd`). SUPER+/.
set -u

hyprctl binds -j | jq -r '
  def mods($m):
    [ (if ($m / 64 | floor) % 2 == 1 then "SUPER" else empty end),
      (if ($m / 4  | floor) % 2 == 1 then "CTRL"  else empty end),
      (if ($m / 8  | floor) % 2 == 1 then "ALT"   else empty end),
      (if $m % 2 == 1 then "SHIFT" else empty end) ];
  def keylabel: (mods(.modmask) + [.key]) | join("+");
  # workspace digit binds are summarised in one line below
  [ .[]
    | select(.has_description)
    | select(.dispatcher != "workspace" and .dispatcher != "movetoworkspace" or (.arg | test("^(prev|special)")))
    | { sub: (if .submap == "" then "" else "[" + .submap + "] " end), key: keylabel, desc: .description } ]
  | (.[] | "\(.sub)\(.key)\t\(.desc)"),
    "SUPER+1..0 / +ALT\tWorkspace 1-10 / 11-20 (add SHIFT to move a window)"
' | column -t -s $'\t' | rofi -dmenu -i -p keys -no-custom -theme-str 'window { width: 880px; } listview { lines: 18; }' >/dev/null
