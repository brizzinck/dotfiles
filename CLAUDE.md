# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Personal dotfiles for an Arch Linux / Hyprland / Wayland setup, managed with **GNU Stow**. Running `stow .` from the repo root symlinks everything into `$HOME`, mirroring the directory structure. Non-config files are excluded via `.stow-local-ignore`.

## Setup

```bash
git clone --recursive <repo>
git submodule update --init --recursive
chmod +x install.sh && ./install.sh
```

`install.sh` does a full machine bootstrap: pacman packages, AUR (via yay), Flatpak apps, Go/NPM/Rust toolchains, Oh My Zsh, Docker setup, SSH key generation, then runs `stow .` to link the dotfiles and `browsers/apply.sh` to copy the browser settings. Root-level system changes (packages, `/etc`, timers, fstab, grub) are applied separately by `sudo ./apply-system.sh`; `./doctor.sh` verifies the result.

After modifying dotfiles, re-apply with:
```bash
cd ~/dotfiles && stow .
```

## Architecture

### Config layout
All configs live under `.config/` following XDG Base Dir. Root-level files (`.zshrc`, `.gitconfig`) stow directly to `$HOME`.

### Monitor management
Static Hyprland rules in `.config/hypr/monitors.lua` (loaded by `hyprland.lua` with `dofile`; `scripts/lid.sh` re-applies the panel rule from the same table): `HDMI-A-1` 2560x1440@144 at `0x0`, the laptop panel `eDP-1` 2880x1800@120 scaled 1.5 at `0x1440` (below the external one), plus a `preferred, auto` fallback for any other output. Hyprland applies them on hotplug, so there is no kanshi, no polling script and no monitor daemon.

### Hyprland config (Lua)
`.config/hypr/hyprland.lua` (+ `monitors.lua`) is the only Hyprland config; there is no `hyprland.conf` (`doctor.sh` checks that it is absent and that the running instance loaded the Lua file). hyprlock, hypridle and the screensaver stay hyprlang. In a Lua config `hyprctl keyword` is gone and `hyprctl dispatch` takes a Lua expression: scripts call `.local/bin/hyprd` (legacy dispatcher names, e.g. `hyprd focuswindow address:0x..`) or `hyprctl eval '<lua>'`. Binds are `hl.bind("SUPER + X", hl.dsp..., { description = "..." })` (descriptions feed the cheatsheet, the hub and `docs/keymap.md`; no commas). `hyprctl binds -j` reports Lua binds as dispatcher `__lua`, so nothing can be read back from it: `hyprland.lua` wraps `hl.bind` and records every dispatcher in a registry, and `hyprctl eval 'df_bind_run("SUPER+Return")'` replays one (mods in SUPER CTRL ALT SHIFT order, key as in the live table, case-insensitive). The hub uses that for its keybind rows (`kind bind`) and for the leader. Hyprland 0.55/0.56 runs a `catchall` bind next to the matching bind and on a lone modifier press (hyprwm/Hyprland#15063), so the repeat modes (`resize`, `mouse`) leave through `leave_on_other_key()`, which ignores the event while one of the mode's own keys or a modifier is held.

### Theme system
Idle (`.config/hypr/hypridle.conf`): dim at 150 s, at 300 s a clock-only hyprlock screensaver (`screensaver.conf`, started by `scripts/screensaver.sh`, no password; any input dismisses it via hypridle on-resume + `SIGUSR1`), panel off (`dpms`) at 1200 s. The machine never suspends or locks by itself, and nothing is killed. All listeners are skipped while media plays or an automation Chrome runs (`idle-allowed.sh`; Wayland/DBus inhibitors are honoured too). `SUPER+Escape` is still the real password lock.

The palette is **Everforest v2** with two switchable variants: **black** (default, pure `#000000` backgrounds) and **night** (near-black `#0a0e0c` content background; bar, lock screen, screensaver and the Hyprland background stay `#000000`). fg, accents and ANSI 0-15 are shared. Source of truth: `themes/palette/everforest.json` (tokens) with the human-readable `themes/palette/palette.md` (token roles, per-app mapping, owner steps). `themes/palette/render.py` (stdlib Python, `PYTHONPYCACHEPREFIX=/tmp/pycache python3 themes/palette/render.py`, `--check` for doctor) renders every `templates/*.tmpl` for both variants into the committed `themes/generated/{black,night}/`; a new app only needs a new template. The active variant is the symlink `~/.local/state/theme/current -> themes/generated/<variant>`, and `theme black|night|toggle|status|init` (`.local/bin/theme`, hub row "Theme: black / night") flips it, reloads ghostty (SIGUSR2), alacritty, every tmux server of the user and nvim, then runs the hooks in `.config/theme/hooks.d/` (`10-hyprland` reload + configerrors check, `20-waybar` SIGUSR2, `30-dunst` `dunstctl reload`, `40-swayosd` restart, `50-qt`). A missing link is recreated as black by `install.sh`, `.zshrc`, tmux.conf and the first Hyprland autostart line.

How each app follows the variant: `hyprland.lua` `dofile`s the black fragment (fallback) and then `current/hyprland.lua` inside `pcall` (a missing or broken fragment is skipped with a notification, black stays); hyprlock and the screensaver (hyprlang) `source` the black fragment and then `current/` (a missing sourced file is a config error, hence the fallback); waybar, wofi, swayosd and both GTK versions `@import` a repo symlink `theme-black.css` plus `theme.css` -> `current/...`; rofi `@import`s the same pair of paths; dunst reads `dunstrc.d/40-theme-black.conf` and `50-theme.conf` drop-ins; btop (`themes/everforest-v2.theme`) and qt6ct (`colors/everforest.conf`) are symlinks to `current/`; lazygit merges `current/lazygit.yml` through `LG_CONFIG_FILE` (set by `.zshrc`, tmux and hub); lazydocker uses ANSI names, so it follows the terminal palette. Literals that cannot follow (pango spans in `waybar/config`, workmux icons) hold token hex and are checked by `doctor.sh`. Generated but applied by hand: `everforest-<variant>.tdesktop-theme` (Telegram), `obsidian.css`, `claude-theme.json`; GTK/Qt apps pick up a switch at their next start. Owner steps are in `themes/palette/palette.md`. `themes/static/everforest-black/` only holds a pointer note now; the other directories in `themes/static/` (rose-pine, dracula, catppuccin-mocha, ...) and `themes/templates/` (matugen, wallust, pywal) are unused leftovers of the old HyprDynamicMonitors setup.

### Launcher
**rofi** is the launcher (`$menu`, `SUPER+space`) and the dmenu backend for the power menu, clipboard history, dunst history, keybind cheatsheet and emoji picker (`.config/rofi/`). wofi stays installed and is themed, but nothing binds it.

### Hubs and window tools
- `hub` (`.config/hub/`, `SUPER+M`, tmux `prefix m`, zsh `hub`): fzf utility hub in a `float.tui` ghostty. Rows come from `actions.tsv` (+ `actions.d/*.tsv`; format in the header of `.config/hub/hub`) merged with every described bind from `hyprctl binds -j`; keybind rows are executable (below); toggles show live ON/OFF; rows whose command is not installed are hidden. `hub open` records the previously focused window (`$XDG_RUNTIME_DIR/hub/prev-window`) so window actions target it. Later stages append rows to `actions.tsv`.
- `scripts/window-menu.sh` (`SUPER+SHIFT+W`, rofi): per-window actions with `address:` dispatchers; `--dry-run --do ID` prints the dispatcher. Extra entries come from executable files in `scripts/window-hooks/` (`# menu: Label` line; run as `hook ADDRESS`).
- `scripts/window-switcher.sh` (`SUPER+SHIFT+space`): fuzzy switcher over all windows. `scripts/safe-close.sh` (`SUPER+W`): double press within 1 s for the classes in `.config/hypr/protected-classes`.
- Desktop vim (V1a): `SUPER+;` is the leader (`wlr-which-key`, AUR): `.config/hub/leader` renders its YAML on every open from the hub rows (`leader` column = `group-key item-key;label`, groups in `.config/hub/leader-groups.tsv`, `leader check|gen|md`), look from the palette (`wlr-which-key.yaml.tmpl`), `auto_kbd_layout` for ua/ru; every item runs `hub --leader ID`, so the leader and the hub cannot drift. Keyboard pointer (`wl-kbptr` + `wlrctl`, AUR): `SUPER+'` hint click, `SUPER+CTRL+'` hint drag, `SUPER+ALT+M` the `mouse` submap, all through `scripts/pointer.sh` (shows a notification when a tool is missing; wl-kbptr reads its labels from the active layout, so the script switches to us and back); overlay colours from `wl-kbptr.conf.tmpl` through `~/.config/wl-kbptr/config`. Window grammar: `SUPER+ALT+H/L` group tab, `SUPER+ALT+J/K` workspace on this monitor, `SUPER+ALT+SHIFT+HJKL` into a group, `SUPER+CTRL+Y` out, `SUPER+ALT+X` dunst context menu (drawn with dunst's `dmenu` = rofi until V1b moves it to the fzf lib). The full grammar is in `docs/keymap.md`.
- Passwords and 2FA: Bitwarden/Vaultwarden through `rbw` + `rofi-rbw` (`SUPER+CTRL+P` passwords, `SUPER+CTRL+O` 2FA codes, waybar `custom/vault`, hub rows in `actions.d/u5.tsv`; logic in `scripts/vault.sh` + `vault-totp.py`). One-time `bw-setup` (asks server URL and e-mail; they live in `~/.config/rbw`, never in the repo); Hyprland runs `vault.sh session-start` (`rbw stop-agent`) at login so the master password is asked once per session. `2fa-import` converts a Google Authenticator export QR into a Bitwarden CSV on tmpfs. User commands live in `.local/bin/` (stowed per file). Copied secrets use `wl-copy --sensitive` (cliphist skips them) and are cleared after 30 s. Full Bitwarden (U6): the desktop app (`bitwarden`, Wayland via `.config/electron39-flags.conf`, floating window rule, waybar middle click) and the official CLI `bw` with hub rows in `actions.d/u6.tsv` (new login, generator, Send text/file, attachments, history, edit, delete; logic in `scripts/vault-bw.py`, session key only in `$XDG_RUNTIME_DIR/vault/bw-session`, cleared with the rbw agent at login and by lock; `bw-setup` also logs `bw` in). Opt-in SSH keys from the vault: `vault.sh ssh-agent on` (flag in `~/.local/state/vault/`) makes shells use the app's `~/.bitwarden-ssh-agent.sock` only while it exists; import a key in the app (New > SSH key), verify with `SSH_AUTH_SOCK=~/.bitwarden-ssh-agent.sock ssh-add -L`. `oo7` is in the package list only to satisfy the `bitwarden` package's `org.freedesktop.secrets` dependency.

### Layout-independent binds (us, ua, ru; Caps toggles)
Rule: every key binding must work while the ua or ru layout is active. Hyprland needs nothing (`resolve_binds_by_sym = false`, binds match layout 1 = us). For everything else, **never hand-type Cyrillic twins**: the single physical-key map is `.config/layout/keymap.tsv`, and `.config/layout/layout.py gen` (stdlib Python, `PYTHONPYCACHEPREFIX=/tmp/pycache`) writes the committed per-tool files: `ghostty/layout-keys.conf` (Alt+physical key sends ESC + us letter: ghostty drops Alt for a Cyrillic character), `tmux/tmux-layout.conf` (twins of every letter bind, read from `tmux list-keys`: rerun after adding tmux binds), `zsh/layout-keys.zsh` (`layout_dup_meta`, `layout_dup_keys` for vi-mode), `layout/layout-keys.sh` (`lk_rofi` for rofi `-kb-custom-N`, `lk_fzf_bind` / `lk_fzf_keys` for fzf letter binds), `rofi/layout-keys.rasi`, and the nvim `lua/configs/layout_data.lua` (langmap + langmapper.nvim). New rofi custom keys use `$(lk_rofi 'Alt+x')`; new fzf letter binds go through `lk_fzf_bind`.

### Docs and tools in the repo (not stowed)
- `doctor.sh` — read-only health check of the approved workstation state (PASS/FAIL per item: lock screen, idle screensaver, hypr-env, ucode, timers, earlyoom, docker GC, pacman cache, pacnew, failed units, zram, Hyprland Lua files/verify/config errors/loaded config, hub bind rows, leader menu, waybar, stow links). Run `./doctor.sh` (`--fails` for failures only).
- `docs/keymap.md` — Hyprland / tmux / shell-helper keymap; regenerate the Hyprland part with `docs/gen-keymap.sh` after changing binds.
- `browsers/` — Zen `user.js` (memory/cache prefs) and Chrome `chrome-flags.conf` (1 GiB disk cache). They must be copied into the flatpak sandboxes, so `browsers/apply.sh` (called by `install.sh`, merges, idempotent) does that instead of stow.
- `pkg/*.txt` — package lists written by a pacman hook; `infrastructure/` — system files installed by `apply-system.sh` / `apply-memory.sh`.

### Neovim
`.config/nvim/` is a git submodule pointing to a custom NvChad fork. Update with `git submodule update --remote`.

### Infrastructure
`infrastructure/systemd/` — `coredump-limits.conf` (installed by `apply-system.sh`) and legacy `hyprdynamicmonitors` user units (unused: monitors are static now).

`infrastructure/tlp/` — TLP drop-in configs (`/etc/tlp.d/`), not stowed (system path, outside `$HOME`, machine-wide rather than per-user). `61-battery-care.conf` caps battery charging; `install.sh` copies it into `/etc/tlp.d/` and enables `tlp.service` (copied, not symlinked, so it doesn't dangle if the installing user's account is later removed on a shared machine). Non-ThinkPad Lenovo hardware (`ideapad_laptop` driver) only supports a binary `Long_Life` charge mode (vendor-fixed ~55-60% cutoff) via the kernel's `charge_types` API — no exact percentage like ThinkPads' `charge_control_end_threshold`. To pick up edits without a full rerun: `sudo cp infrastructure/tlp/61-battery-care.conf /etc/tlp.d/ && sudo systemctl restart tlp`.

`infrastructure/memory/` — RAM safety net, copied (not stowed) into `/etc` by `install.sh`: zram swap (`zram-generator.conf`), sysctl tuning, zswap off (avoids double compression), journald cap. (`daemon.json` with log limits and the BuildKit GC cap now lives here too but is installed by `apply-system.sh`.) Apply (or re-apply after edits) without a full rerun: `./apply-memory.sh` (self-elevates with sudo, idempotent).

`apply-system.sh` — one idempotent root script for the whole system layer (sections `cleanup upgrade install remove config services disk boot flatpak summary`; `--dry-run`, `--only <section>`). It installs `infrastructure/{memory/earlyoom,memory/docker-daemon.json,pacman/*.hook,systemd/coredump-limits.conf,tlp/62-power.conf}` into `/etc`, edits `makepkg.conf`/`pacman.conf`/`fstab`/`grub`, and keeps `pkg/{native,aur,flatpak}.txt` current through a pacman hook (`/usr/local/bin/dotfiles-pkglist`, rendered from `infrastructure/pacman/dotfiles-pkglist.in`). Run: `sudo ./apply-system.sh` (preview: `./apply-system.sh --dry-run`).

### Shell aliases (`.zshrc`)
- `gtx` navigation: `gtj`=~/job, `gtd`=~/dotfiles, `gtn`=~/.config/nvim
- Git: `gs`, `ga`, `gcm`, `gp`, `gl`, etc.
- Go: `tg` (test all), `lg` (lint+tidy), `grun` (smart run, finds main.go; was `rg`, which shadowed ripgrep)
- Helpers: `sysup` (system upgrade), `vpn` (fzf VPN toggle), `jf` (fuzzy journal), `lzd` (lazydocker), `tp` (trash-put); full list in `docs/keymap.md`
- Rust/Cargo: `rr`=run, `rc`=clippy, `of()` (fmt with edition flag)

## AI agent cockpit (Neovim + tmux)

`install.sh` is idempotent and user-agnostic: no usernames, home paths or e-mails are hardcoded.
Git identity lives in `~/.gitconfig.local` (written by `install.sh`, included from `.gitconfig`).
After `stow .` it runs `.config/nvim/scripts/bootstrap.lua` headless, which restores plugins from
`lazy-lock.json`, installs Mason tools and treesitter parsers, and writes the agent hooks
(`:AgentDashInstallHooks`) into `~/.claude/settings.json` / `~/.codex/hooks.json` with backups.

Neovim side (`lua/plugins/ai/*.lua`, all keys under `<leader>a`):
- `sidekick.nvim` — Claude/Codex/Gemini CLIs in persistent tmux windows, context prompts
- `agentic.nvim` — ACP quick chat (`claude-agent-acp`, `codex-acp`)
- `codediff.nvim` + `review.nvim` — post-hoc review, comments sent back to the agent
- `mcphub.nvim` — one MCP endpoint (`localhost:37373`) shared by all agents; servers in `.config/mcphub/servers.json`
- `lua/agentdash/` — custom dashboard of sessions/subagents/tasks fed by agent hooks (`:AgentDash`, statusline segment)
- `workmux` (`.config/workmux/config.yaml`) — git worktree + tmux window per agent task, `<leader>aw*`

Installing new nvim plugins: use `nvim --headless "+Lazy! install" +qa`, never `Lazy sync`/`clean`
(they bump every pinned commit in `lazy-lock.json`).
