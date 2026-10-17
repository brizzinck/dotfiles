# Everforest palette v2 (human-readable source of truth)

Two variants share fg, accents and ANSI 0-15; only the background family differs.

- **black** (default, "Everforest Black Refined"): pure `#000000` content background.
- **night** ("Everforest Night"): forest-tinted near-black `#0a0e0c`; no OLED smear when scrolling, same look on the
  OLED and IPS panels. The bar, lock screen, screensaver and Hyprland background stay `#000000` (`bg_oled`).

The machine-readable twin is `everforest.json` (this directory). `render.py` turns it plus `templates/*.tmpl` into
`../generated/{black,night}/` (committed). Edit the JSON, run
`PYTHONPYCACHEPREFIX=/tmp/pycache python3 themes/palette/render.py`, commit `themes/generated/`
(`render.py --check` and `doctor.sh` fail when they drift). The design study with all measurements (WCAG, APCA,
OKLCH, colour-blind checks, candidates C and the rejected options) is in the workstation-overhaul notes
(`palette-v2.md`); the numbers here are its candidates A and B.

## Switching

`theme black | night | toggle | status` (`~/.local/bin/theme`, hub row "Theme: black / night"). The active
variant is the symlink `~/.local/state/theme/current -> ~/dotfiles/themes/generated/<variant>`; `theme init`
(install.sh, `.zshrc`, tmux.conf) recreates it as black when it is missing. Apps include their fragment through
that path:

| app | include |
|---|---|
| ghostty | `config-file = ?~/dotfiles/themes/generated/black/ghostty.conf` (fallback) then `?~/.local/state/theme/current/ghostty.conf` |
| alacritty | `[general] import` of the same two files |
| tmux | `source-file -q ~/.local/state/theme/current/tmux.conf` (after `theme init` when missing) |
| fzf | `FZF_DEFAULT_OPTS_FILE=~/.local/state/theme/current/fzfrc` (zsh, tmux environment, hub and fzf scripts) |
| git / delta | `[include]` of `generated/black/delta.gitconfig`, then `current/delta.gitconfig` |
| nvim | `lua/palette.lua` reads `current/tokens.json` (fallback `generated/black`), per-variant base46 cache |
| Hyprland | `hyprland.lua` `dofile`s `~/dotfiles/themes/generated/black/hyprland.lua` (fallback) then `~/.local/state/theme/current/hyprland.lua`, each inside `pcall` (a missing or broken fragment is skipped with a notification and the black one stays) |
| hyprlock, screensaver | same pair of `source` lines for `generated/*/hyprlock.conf` (`$ef_*` variables; `$ef_hex_*` for pango spans) |
| waybar, wofi, swayosd | `@import "theme-black.css"; @import "theme.css";` in their stylesheet; both are repo symlinks (`generated/black/waybar.css` and `current/waybar.css`), the file holds `@define-color` names = tokens |
| rofi | `@import` of `~/dotfiles/themes/generated/black/rofi.rasi` then `~/.local/state/theme/current/rofi.rasi` (a missing import is silent) |
| dunst | drop-ins `.config/dunst/dunstrc.d/40-theme-black.conf` and `50-theme.conf` (symlinks to the generated `dunstrc`), `dunstctl reload` |
| GTK 3 / GTK 4 | `gtk.css` imports `theme-black.css` and `theme.css` (symlinks to `generated/*/gtk3.css`, `gtk4.css`) |
| qt6ct, btop | `colors/everforest.conf` and `themes/everforest-v2.theme` are symlinks to `current/qt6ct.conf` and `current/btop.theme` |
| lazygit | `LG_CONFIG_FILE=~/.config/lazygit/config.yml,current/lazygit.yml` (set by `.zshrc`, tmux and hub only when the file exists) |
| Zen (later) | `current/tokens.css` (`--ef-*` variables, dashes: `--ef-fg-hi`, `--ef-subtext`, `--ef-muted`, `--ef-bg-oled`) and `current/tokens.json` |
| Claude Code | `current/claude-theme.json`, copied by the owner (see below) |

Live reload on `theme ...`: ghostty `SIGUSR2`, alacritty config touch, `tmux source-file` on every tmux server of
the user, nvim `palette.reload()` through its server sockets, then the hook scripts in
`~/.config/theme/hooks.d/*.sh` (`.config/theme/hooks.d/` in this repo; the desktop layer plugs in there).

## Tokens

| token | black | night | role |
|---|---|---|---|
| `bg_oled` | `#000000` | `#000000` | waybar, hyprlock, screensaver, Hyprland background (always pure black, both variants) |
| `bg` | `#000000` | `#0a0e0c` | terminal, nvim Normal, tmux default, rofi, dunst, wofi, GTK/Qt window, Zen content |
| `surface` | `#0d1210` | `#121815` | cursorline, pmenu, floats, tooltips, headerbar/sidebar/cards |
| `raised` | `#151b18` | `#19201c` | statusline pills, tmux current window, active workspace pill, Claude user-message slab, inactive selection |
| `select` | `#1e2822` | `#212c26` | selected row (lazygit, rofi, fzf bg+, telescope), ANSI 0 |
| `visual` | `#28352d` | `#2c3931` | Visual mode, terminal selection, tmux copy selection, Qt Highlight |
| `line` | `#272f2b` | `#2c3430` | splits, inactive pane/window border, indent rails, separators (>= 1.5:1 against bg) |
| `border` | `#3e4843` | `#424c47` | float borders, prompt border, inactive group border, lock ring, LineNr in nvim |
| `muted` | `#6c7871` | `#6f7b74` | ANSI 8, autosuggestions, placeholders, disabled, tertiary text |
| `comment` | `#6e936e` | `#719671` | code comments in nvim, Obsidian, Zen code blocks (terminal tools use ANSI 8) |
| `subtext` | `#8d998f` | `#909c92` | secondary text, idle bar text, Claude inactive, fzf header, rofi descriptions |
| `fg_dim` | `#b3b4a6` | `#b4b6a7` | ANSI 7, tertiary emphasis, Claude shimmer |
| `fg` | `#dbd8c9` | `#dbd8c9` | primary text everywhere |
| `fg_hi` | `#e9e6db` | `#e9e6db` | ANSI 15, cursor, headings, selected text |
| `cursor_text` | `#000000` | `#0a0e0c` | text under the terminal cursor (= bg) |
| `red` | `#e88384` | `#e88384` | error, danger, critical, recording, REPLACE, git deleted, keyword (nvim) |
| `orange` | `#ea9e77` | `#ea9e77` | caution levels (battery 30 %, volume > 100 %, mic in use), escapes/tags, Claude brand |
| `yellow` | `#d9bc7f` | `#d9bc7f` | attention + warning: PREFIX, submap, urgent workspace, git modified, DiagnosticWarn, current search match, strings |
| `green` | `#abc682` | `#abc682` | focus/primary: active border, active workspace, NORMAL, success, git added, functions, fzf/telescope match |
| `aqua` | `#8cc69c` | `#8cc69c` | healthy/connected, TERMINAL, hint, types, plan mode |
| `blue` | `#83c3c8` | `#83c3c8` | info, links, INSERT, copy-mode, search match, directories/path, properties |
| `purple` | `#dca0bb` | `#dca0bb` | special: scratchpad, groups, VISUAL, DND, zoom, numbers/constants/punctuation, git branch |
| `red_soft` | `#8b4f4f` | `#8b4f4f` | calm alert tint: `red` blended 60 % toward the bar black (waybar critical: failed units, recording, battery low) |
| `yellow_soft` | `#82714c` | `#82714c` | calm alert tint: `yellow` blended 60 % toward the bar black (waybar warning, urgent workspace, mic in use) |
| `diff_add_bg` | `#192616` | `#1f2c1c` | diff line background (nvim, delta, Claude) |
| `diff_del_bg` | `#2b1516` | `#311b1b` | diff line background |
| `diff_chg_bg` | `#0f2022` | `#152729` | diff line background |
| `diff_add_word` | `#2c3f21` | `#324527` | diff changed-word background |
| `diff_del_word` | `#4c2426` | `#532b2c` | diff changed-word background |
| `diff_chg_word` | `#17393d` | `#1e4044` | diff changed-word background |
| `error_bg` | `#1f1212` | `#261818` | diagnostic virtual-text background |
| `warn_bg` | `#1a160d` | `#201c12` | diagnostic virtual-text background |
| `info_bg` | `#0d1819` | `#131e1f` | diagnostic virtual-text background |
| `hint_bg` | `#101912` | `#161f18` | diagnostic virtual-text background |
| `green_soft` | `#67774e` | `#67774e` | calm tint of `green` (60 % of it on black, like `red_soft`): Hyprland active window border |
| `purple_soft` | `#846070` | `#846070` | calm tint of `purple` (60 % of it on black): Hyprland group border and active groupbar tab |
| `*_br` | `#f99b9b`, `#fab592`, `#ead19d`, `#c2da9e`, `#a7d9b4`, `#a2d5d9`, `#ecb7cf` | same | bright ANSI 9-14 (red, orange, yellow, green, aqua, blue, purple order; orange_br has no ANSI slot) |


ANSI order everywhere: `0 select, 1 red, 2 green, 3 yellow, 4 blue, 5 purple, 6 aqua, 7 fg_dim, 8 muted,
9 red_br, 10 green_br, 11 yellow_br, 12 blue_br, 13 purple_br, 14 aqua_br, 15 fg_hi`; terminal fg = `fg`, bg = `bg`,
cursor = `fg_hi` with text `bg`, selection = `visual`, `faint-opacity` 0.75 (black) / 0.74 (night),
`minimum-contrast` 1.5. ANSI 0 is a subtle surface on purpose: TUIs that paint `bg=black` get a quiet panel and
`fg=black` badges keep their contrast.

| ANSI | black | night | ANSI | black | night |
|---|---|---|---|---|---|
| 0 | `#1e2822` | `#212c26` | 8 | `#6c7871` | `#6f7b74` |
| 1 | `#e88384` | `#e88384` | 9 | `#f99b9b` | `#f99b9b` |
| 2 | `#abc682` | `#abc682` | 10 | `#c2da9e` | `#c2da9e` |
| 3 | `#d9bc7f` | `#d9bc7f` | 11 | `#ead19d` | `#ead19d` |
| 4 | `#83c3c8` | `#83c3c8` | 12 | `#a2d5d9` | `#a2d5d9` |
| 5 | `#dca0bb` | `#dca0bb` | 13 | `#ecb7cf` | `#ecb7cf` |
| 6 | `#8cc69c` | `#8cc69c` | 14 | `#a7d9b4` | `#a7d9b4` |
| 7 | `#b3b4a6` | `#b4b6a7` | 15 | `#e9e6db` | `#e9e6db` |

The tinted 232-255 grey ramp from the design study is kept in `everforest.json` but not applied (optional).

## Semantic roles (one meaning everywhere)

| role | token |
|---|---|
| focus / primary / success: active border, active workspace, NORMAL, tmux current window, fzf match + pointer, git added | `green` |
| attention / warning: tmux PREFIX, submap, urgent workspace, git modified, DiagnosticWarn, current search match | `yellow` |
| caution levels: battery 30 %, volume > 100 %, mic in use, caps lock, workmux waiting, Claude brand | `orange` |
| danger / error: errors, critical notifications, recording, failed units, SYNC, REPLACE, git deleted, lock fail | `red` |
| info / navigation: links, INSERT, copy mode, search matches, directories and paths | `blue` |
| healthy / hint: VPN on, charging, TERMINAL, DiagnosticHint, types | `aqua` |
| special: scratchpad, groups, VISUAL, DND, zoom, git branch | `purple` |
| selection | `visual` (text), `select` (list rows), `raised` (inactive selection) |
| borders | active `green_soft`; inactive `line`; groups `purple_soft` / `line`; no shadow |
| wallpaper | figure `green_soft` on `bg_oled` |
| text | primary `fg`, secondary `subtext`, tertiary and disabled `muted`, code comments `comment` |
| diff | add `diff_add_bg` / `diff_add_word`, delete `diff_del_bg` / `diff_del_word`, change `diff_chg_bg` / `diff_chg_word`; signs `green` / `red` / `yellow` |

## Mapping per tool

Terminal layer and nvim (applied):

| tool | where | notes |
|---|---|---|
| ghostty | `.config/ghostty/config` + `generated/*/ghostty.conf` | fg/bg/cursor/selection, palette 0-15, `faint-opacity`, `minimum-contrast` |
| alacritty | `.config/alacritty/alacritty.toml` + `generated/*/alacritty.toml` | same colours as ghostty |
| tmux | `.config/tmux/tmux.conf` + `generated/*/tmux.conf` | status, windows, pane borders, messages, copy mode, popups, menus; structure stays in tmux.conf |
| zsh | `.zshrc` | prompt arrow green/red, dir blue, git branch purple, dirty yellow; autosuggestions and comments `fg=8`; `LS_COLORS` ow/tw/st fixed; `EZA_COLORS` punctuation |
| fzf | `generated/*/fzfrc` | `bg:-1` (terminal bg), `bg+` select, hl/pointer green, marker yellow |
| delta | `generated/*/delta.gitconfig` | diff colours from the diff tokens |
| bat, git, lazydocker, yazi | ANSI | inherit the terminal palette |
| man / less | `.zshrc` `MANPAGER` | bold green, underline blue |
| nvim | `.config/nvim/lua/{palette,chadrc}.lua` | base46 everforest with every base_30/base_16 value from the tokens, `terminal_color_0..15` |
| Claude Code | `generated/*/claude-theme.json` | 72-key custom theme, owner copies it to `~/.claude/themes/` |

Desktop layer (applied, stage T1b; section 5.3 of the design study has the full token-per-setting table):

| tool | how | notes |
|---|---|---|
| Hyprland | `hyprland.lua` fragment (`hl.config`) | active border `green_soft` (solid: a green -> aqua gradient banded on a 2-3 px stripe), inactive `line`, no shadow (the `glow` token is gone), groups `purple_soft` (border and active tab) / `line` (border) / `border` (inactive tab), blocked grouping `yellow_soft`, `misc.background_color` `bg_oled`; `dim_strength` 0.10 (0.15 turned fg khaki) |
| wallpaper | `wallpaper.svg` (vector, committed per variant) | the figure (one path group, the owner's two-tone art) is `green_soft`, the background is `bg_oled` (same in black and night; the Hyprland background stays `#000000`). Only the vector is committed; `.config/hypr/scripts/wallpaper.sh` renders a PNG per output at its native physical size into `~/.cache/wallpaper/` and runs one `swaybg` per output (art fitted whole, rest `bg_oled`). A token change re-renders (the cache key holds the SVG hash). Re-trace recipe: header of `wallpaper.sh`. Owner steps: none |
| hyprlock, screensaver | `$ef_*` variables | background `bg_oled`, ring `border`, text `fg`, date `subtext`, hint and placeholder `muted`, check `yellow`, fail `red`, caps `orange` |
| greeter (login screen) | `greeter-palette.qml` (QML singleton `Theme`; `Theme.alpha(colour, a)` for the halo, the `glow` token is not emitted because QML reads #AARRGGBB) | `infrastructure/greetd/greeter/Theme.qml` links to `generated/black/greeter-palette.qml` and `apply-system.sh --only greeter` installs it as `/etc/greetd/greeter/Theme.qml`: the greeter is system-wide and always black (like hyprlock): background `bg_oled`, clock `fg`, date `subtext`, input outline `border` / focused `green` / checking `yellow` / failed `red`, placeholder and bar `muted`, avatar ring and halo `green` (Other user `aqua`), menu `surface` + `border`, selected row `select`. After a palette change rerun `render.py` and `sudo ./apply-system.sh --only greeter` (`doctor.sh` flags the drift once greetd is enabled) |
| pointer (cursor) | `pointer.json` (`fill` = `green`, `outline` = `bg_oled`, `accent` = `bg_oled`) | local package `infrastructure/cursor/everforest-cursor-theme` (PKGBUILD): Bibata Modern vector art recoloured through rtgiskard/bibata_cursor, hyprcursor SVG + XCursor build in `/usr/share/icons/Everforest-Cursor`. Built by `apply-system.sh` / `install.sh` (`infrastructure/cursor/build.sh`); the pointer does **not** follow `theme black\|night` (shared tokens only). After a palette change rerun `render.py` and `sudo ./apply-system.sh --only install` (the build stamp in the theme tells `doctor.sh` and the script when it is stale). The busy cursor's four hard-coded Windows-colour pies become `accent` (dark `bg_oled` pies on the green disk) |
| waybar | `@define-color` names (incl. `red_soft`, `yellow_soft`) | bar on `bg_oled`, tooltip `surface` + `border`; roles: `subtext` normal, `muted` dim / off / inactive (layout indicator, mode icon), `fg` clock and hover (on a `surface` pill), `green` active workspace / submap (on `raised`) / enabled switch, `yellow_soft` warning and `red_soft` critical (calm tints of yellow and red, text colour only: no pill, no bold; a bright alert colour was rejected as too loud). Scripts print one class per state (`normal`, `dim`, `enabled`, `warning`, `critical`) and `style.css` maps them; no hex in `style.css`. The only literals are the pango spans of the clock calendar in `modules.jsonc` (black-variant hex of `fg`, `subtext`, `muted`, `green`; night differs by <= 3/255 on `muted` and `subtext`); `doctor.sh` checks they are tokens |
| rofi, wofi | token names | window `bg`, border `border`, selected row `select` with `green` text, placeholder `subtext`, urgent `red`, active `blue` |
| dunst | drop-in | low `border` frame / `subtext` text, normal `blue` frame / `green` highlight, critical `red`; recorder red, idle yellow, battery orange |
| swayosd | `style.css` | `bg_oled` pill, `border` frame, `fg` text, `line` trough, `green` bar |
| GTK 3 / 4 | `gtk3.css`, `gtk4.css` | libadwaita variables and `@define-color` names: windows `bg`, header/side/cards `surface`, text `fg` (no libadwaita white), accent `green` with `bg` text; gsettings `accent-color` is `green` (closest enum value; the CSS accent is the exact token) |
| Qt | `qt6ct.conf` | 21 roles x active/disabled/inactive; Highlight `visual`, Link `blue`, disabled text `muted` |
| btop | `btop.theme` | gradients green -> yellow -> red, boxes `border`, dividers `line`, main_bg empty (terminal background) |
| lazygit | `lazygit.yml` | active border `green`, inactive `line`, selected row `select`, options `blue`, search `yellow`; lazydocker keeps ANSI names (terminal palette) |
| Vimium C | `vimium-c.css`, embedded in `browsers/vimium-c.json` | link hints `bg_oled` with a `green` frame and `yellow` typed prefix, hover highlight `green`, HUD / find bar `surface`, Vomnibar `bg` / `surface` with `select` for the chosen row; import by hand (`browsers/README.md`) |
| Telegram, Obsidian | generated, applied by hand | see below |

What follows a switch live: Hyprland (reload), waybar (SIGUSR2), dunst (reload), swayosd (restart), terminals, tmux, nvim. At the next start only: GTK and Qt apps (qt6ct is nudged by a touch of `qt6ct.conf`), btop, lazygit, rofi, wofi, hyprlock. Telegram, Obsidian and Claude Code need the manual steps below.

## Telegram and Obsidian (owner steps)

- **Telegram Desktop**: `themes/generated/<variant>/everforest-<variant>.tdesktop-theme` is a complete theme (all 467 keys, derived from the stock Night theme, so nothing falls back to the light Day palette; the design study had asked for an export of Night, the copy shipped in tdesktop's `Telegram/Resources/night.tdesktop-theme` was used instead). Send the file to *Saved Messages* and open it ("Apply this theme"), or Settings > Chat Settings > Choose from file. Telegram has no auto-load: re-apply after a variant switch or a palette change. It was generated without a visual check; report keys that look wrong and fix them in `templates/telegram.colors.tmpl` (accents are `green` fills with `bg` text, the selected chat and own messages use `select`).
- **Obsidian**: copy `themes/generated/<variant>/obsidian.css` to `<vault>/.obsidian/snippets/everforest.css` and enable it in Settings > Appearance > CSS snippets. Nothing writes into the vaults.
- **GTK apps** already running keep the old colours until restarted.

## Claude Code and Codex (owner steps, agents may not write to `~/.claude` or `~/.codex`)

1. `cp ~/dotfiles/themes/generated/black/claude-theme.json ~/.claude/themes/everforest-black.json` and
   `cp ~/dotfiles/themes/generated/night/claude-theme.json ~/.claude/themes/everforest-night.json`.
2. In Claude Code run `/theme` and pick "Everforest Black Refined" (setting `custom:everforest-black`) or
   "Everforest Night (near-black)" (`custom:everforest-night`). The theme has to match the active variant: the
   backgrounds of the user-message slab and diffs differ. Re-copy after every palette change.
3. Codex: `/theme` and choose the ANSI-based syntax theme (or `base16`), so code blocks follow the terminal palette.
