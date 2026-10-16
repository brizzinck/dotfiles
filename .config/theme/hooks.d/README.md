# theme hooks

`theme black|night|toggle` runs every executable `*.sh` in this directory, in name order, after it has flipped
`~/.local/state/theme/current` and reloaded the terminal layer (ghostty, alacritty, tmux, nvim).

Each hook is called as `hook <variant>` with `THEME_VARIANT` (`black` or `night`) and `THEME_DIR`
(`~/.local/state/theme/current`, the active generated fragments) in the environment. It must be safe on a live
session: never kill or restart the user's apps, never lock or suspend, no prompts. A failing hook is reported
and does not abort the switch.

Shipped hooks (name order): `10-hyprland.sh` (`hyprctl reload` only when the live colours differ, then `configerrors`
must be empty), `20-waybar.sh` (`bar.sh reload`: render the bar state, then SIGUSR2), `30-dunst.sh` (`dunstctl reload`, notifications untouched),
`40-swayosd.sh` (restart the server, which reads its CSS only at start), `50-qt.sh` (touch `qt6ct.conf`).
Apps without a hook read the variant at their next start (GTK, btop, lazygit, rofi, wofi, hyprlock). Fragments come
from `themes/palette/templates/`; palette.md lists which app imports which file.
