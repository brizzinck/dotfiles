#!/usr/bin/env bash
# Keybind cheatsheet (fzf-menu, vim keys) from the live bind table (descriptions come from the Lua binds). SUPER+/.
set -u

hyprctl binds -j | jq -r '
  def mods($m):
    [ (if ($m / 64 | floor) % 2 == 1 then "SUPER" else empty end),
      (if ($m / 4  | floor) % 2 == 1 then "CTRL"  else empty end),
      (if ($m / 8  | floor) % 2 == 1 then "ALT"   else empty end),
      (if $m % 2 == 1 then "SHIFT" else empty end) ];
  def keylabel: if .catch_all then "any other key" else (mods(.modmask) + [.key]) | join("+") end;
  # workspace digit binds are summarised in one line below
  [ .[]
    | select(.has_description)
    | select(.description | test("^(Move window to )?[Ww]orkspace [0-9]+$") | not)
    | { sub: (if .submap == "" then "" else "[" + .submap + "] " end), key: keylabel, desc: .description } ]
  | (.[] | "\(.sub)\(.key)\t\(.desc)"),
    "SUPER+1..0 / +ALT\tWorkspace 1-10 / 11-20 (add SHIFT to move a window)"
' | column -t -s $'\t' | fzf-menu -p keys --header 'Esc: normal mode   /: search   q: close' >/dev/null
