# theme hooks

`theme black|night|toggle` runs every executable `*.sh` in this directory, in name order, after it has flipped
`~/.local/state/theme/current` and reloaded the terminal layer (ghostty, alacritty, tmux, nvim).

Each hook is called as `hook <variant>` with `THEME_VARIANT` (`black` or `night`) and `THEME_DIR`
(`~/.local/state/theme/current`, the active generated fragments) in the environment. It must be safe on a live
session: never kill or restart the user's apps, never lock or suspend, no prompts. A failing hook is reported
and does not abort the switch.

The desktop layer (Hyprland, waybar, dunst, rofi, swayosd, GTK, Qt, btop, lazygit, ...) plugs in here, for
example `10-desktop.sh` reloading waybar and dunst. Fragments come from `themes/palette/templates/`.
