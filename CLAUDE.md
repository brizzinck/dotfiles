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
Static Hyprland rules in the `monitors` block of `.config/hypr/hyprland.conf`: `HDMI-A-1` 2560x1440@144 at `0x0`, the laptop panel `eDP-1` 2880x1800@120 scaled 1.5 at `0x1440` (below the external one), plus a `preferred, auto` fallback for any other output. Hyprland applies them on hotplug, so there is no kanshi, no polling script and no monitor daemon.

### Theme system
Idle (`.config/hypr/hypridle.conf`): dim at 150 s, at 300 s a clock-only hyprlock screensaver (`screensaver.conf`, started by `scripts/screensaver.sh`, no password; any input dismisses it via hypridle on-resume + `SIGUSR1`), panel off (`dpms`) at 1200 s. The machine never suspends or locks by itself, and nothing is killed. All listeners are skipped while media plays or an automation Chrome runs (`idle-allowed.sh`; Wayland/DBus inhibitors are honoured too). `SUPER+Escape` is still the real password lock.

The active palette is **Everforest Black** (pure `#000000` backgrounds), stored in `themes/static/everforest-black/` (`palette.md` is the source of truth; `waybar.css`, `rofi.rasi`, `ansi.txt` are reusable fragments). It is applied to ghostty, alacritty, tmux, nvim, Hyprland, hyprlock, waybar, rofi, wofi, dunst, lazygit, lazydocker, btop, GTK (prefer-dark) and Qt (`.config/qt6ct`). The other directories in `themes/static/` (rose-pine, dracula, catppuccin-mocha, ...) and `themes/templates/` (matugen, wallust, pywal) are unused leftovers of the old HyprDynamicMonitors setup.

### Launcher
**rofi** is the launcher (`$menu`, `SUPER+space`) and the dmenu backend for the power menu, clipboard history, dunst history, keybind cheatsheet and emoji picker (`.config/rofi/`). wofi stays installed and is themed, but nothing binds it.

### Docs and tools in the repo (not stowed)
- `doctor.sh` — read-only health check of the approved workstation state (PASS/FAIL per item: lock screen, idle screensaver, hypr-env, ucode, timers, earlyoom, docker GC, pacman cache, pacnew, failed units, zram, Hyprland config errors, waybar, stow links). Run `./doctor.sh` (`--fails` for failures only).
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
