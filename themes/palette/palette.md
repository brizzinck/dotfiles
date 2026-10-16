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
| Zen (later) | `current/tokens.css` (`--ef-*` variables) and `current/tokens.json` |
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
| `glow` | `#abc6822e` | `#abc6822e` | Hyprland shadow (green + alpha 2e) |
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
| borders | active `green`; inactive `line`; floats `border` |
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

Desktop layer (generated fragments `waybar.css`, `rofi.rasi`, `ansi.txt`, `tokens.css` exist; wiring is stage T1b):
Hyprland, hyprlock, screensaver, waybar, rofi, wofi, dunst, swayosd, GTK 3/4, qt6ct, btop, lazygit, Telegram and
Obsidian files. The target mapping per setting is in the design study (`palette-v2.md` section 5.3).

## Claude Code and Codex (owner steps, agents may not write to `~/.claude` or `~/.codex`)

1. `cp ~/dotfiles/themes/generated/black/claude-theme.json ~/.claude/themes/everforest-black.json` and
   `cp ~/dotfiles/themes/generated/night/claude-theme.json ~/.claude/themes/everforest-night.json`.
2. In Claude Code run `/theme` and pick "Everforest Black Refined" (setting `custom:everforest-black`) or
   "Everforest Night (near-black)" (`custom:everforest-night`). The theme has to match the active variant: the
   backgrounds of the user-message slab and diffs differ. Re-copy after every palette change.
3. Codex: `/theme` and choose the ANSI-based syntax theme (or `base16`), so code blocks follow the terminal palette.
