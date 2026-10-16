# Everforest Black (OLED)

Everforest accents on a pure `#000000` base. Single source of truth for waybar, rofi, wofi,
dunst, ghostty, alacritty, tmux, nvim, lazygit, btop, hyprlock and GTK/Qt. Contrast ratios are WCAG
against `#000000`. Reusable fragments in this directory: `waybar.css`, `rofi.rasi`, `ansi.txt`.

## Neutrals (all backgrounds stay `#000000`)

| Token | Hex | Contrast | Use |
|---|---|---|---|
| `bg` | `#000000` | n/a | every background: terminal, bar, launcher, notifications, floats, lock screen |
| `surface` | `#0b0e0d` | n/a | cursorline, hover, tooltip/message boxes |
| `raised` | `#141a17` | n/a | active workspace pill, tmux current-window pill, inactive bar pill |
| `select` | `#1f2a24` | n/a | selected list row (lazygit, rofi, telescope), ANSI 0 |
| `visual` | `#2a3530` | n/a | Visual mode, terminal selection, tmux copy selection |
| `line` | `#222a27` | 1.4:1 | splits, inactive pane border, inactive Hyprland border |
| `border` | `#3a4440` | 2.1:1 | float borders, inactive panel borders, dunst low frame |
| `muted` | `#6b7770` | 4.5:1 | ANSI 8, line numbers, inactive labels, zsh autosuggestions |
| `subtext` | `#859289` | 6.5:1 | secondary text, idle bar text |
| `fg` | `#d3c6aa` | 12.4:1 | primary text |
| `fg_hi` | `#e7dabe` | 15.2:1 | headings, ANSI 15, cursor |

## Accents and their meaning

| Token | Hex | Contrast | Meaning |
|---|---|---|---|
| `green` | `#a7c080` | 10.5:1 | focus / primary: active border, active workspace, NORMAL mode, success, git added |
| `aqua` | `#83c092` | 9.9:1 | healthy and connected: VPN on, charging, TERMINAL mode |
| `blue` | `#7fbbb3` | 9.7:1 | info, copy-mode, INSERT mode, links, normal-urgency frame |
| `yellow` | `#dbbc7f` | 11.5:1 | attention: tmux PREFIX, submap, urgent workspace, git modified, COMMAND mode |
| `orange` | `#e69875` | 9.1:1 | warning: battery 30%, volume above 100%, mic in use |
| `red` | `#e67e80` | 7.7:1 | danger: error, critical, recording, failed units, mic muted, REPLACE mode |
| `purple` | `#d699b6` | 9.1:1 | special: scratchpad/special workspace, groups, VISUAL mode, DND, zoom |

## ANSI terminal palette

```
0  #1f2a24   8  #6b7770
1  #e67e80   9  #f29a9b
2  #a7c080  10  #bfd39a
3  #dbbc7f  11  #e8cc96
4  #7fbbb3  12  #98cdc5
5  #d699b6  13  #e3b0c8
6  #83c092  14  #9ad1a8
7  #b8ae96  15  #e7dabe
fg #d3c6aa  bg #000000  cursor #e7dabe  selection-bg #2a3530
```

ANSI 0 is a subtle surface on purpose: TUIs that paint `bg=black` get a visible but quiet panel, and
`fg=black` badges keep high contrast.

## Mapping per tool

| Tool | Where | Set |
|---|---|---|
| ghostty | `.config/ghostty/config` | ANSI palette, fg/bg, cursor, selection |
| alacritty | `.config/alacritty/alacritty.toml` | same 16 colors |
| tmux | `.config/tmux/tmux.conf` | status, pane borders, mode and message styles |
| nvim | `nvim/lua/chadrc.lua` | base46 everforest with black neutrals |
| Hyprland | `.config/hypr/hyprland.conf` | active border `green`/`aqua`, inactive `line`, group `purple` |
| hyprlock | `.config/hypr/hyprlock.conf` | bg `bg`, ring `border`, check `yellow`, fail `red`, caps `orange` |
| waybar | `.config/waybar/style.css` | `@define-color` tokens (see `waybar.css`) |
| rofi | `.config/rofi/config.rasi` | tokens (see `rofi.rasi`) |
| wofi | `.config/wofi/style.css` | opaque `bg`, `border`, accent `green` |
| dunst | `.config/dunst/dunstrc` | bg `bg`; low `border`, normal `blue`, critical `red` frame |
| lazygit / lazydocker / btop | `.config/{lazygit,lazydocker,btop}` | `green`/`border`, selected `select`, btop everforest-dark-hard |
| GTK | gsettings + `gtk-3.0/settings.ini` + `gtk-4.0/gtk.css` | prefer-dark, Adwaita-dark, black libadwaita overrides |
| Qt | `qt6ct/qt6ct.conf` + `qt6ct/colors/everforest-black.conf` | Fusion with this palette |
| cursor | Hyprland env + gsettings | Bibata-Modern-Ice, size 32 |
