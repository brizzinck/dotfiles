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

### Hubs and window tools
- `hub` (`.config/hub/`, `SUPER+M`, tmux `prefix m`, zsh `hub`): fzf utility hub in a `float.tui` ghostty. Rows come from `actions.tsv` (+ `actions.d/*.tsv`; format in the header of `.config/hub/hub`) merged with every `bindd` from `hyprctl binds -j`; toggles show live ON/OFF; rows whose command is not installed are hidden. `hub open` records the previously focused window (`$XDG_RUNTIME_DIR/hub/prev-window`) so window actions target it. Later stages append rows to `actions.tsv`.
- `scripts/window-menu.sh` (`SUPER+SHIFT+W`, rofi): per-window actions with `address:` dispatchers; `--dry-run --do ID` prints the dispatcher. Extra entries come from executable files in `scripts/window-hooks/` (`# menu: Label` line; run as `hook ADDRESS`).
- `scripts/window-switcher.sh` (`SUPER+SHIFT+space`): fuzzy switcher over all windows. `scripts/safe-close.sh` (`SUPER+W`): double press within 1 s for the classes in `.config/hypr/protected-classes`.
- Passwords and 2FA: Bitwarden/Vaultwarden through `rbw` + `rofi-rbw` (`SUPER+CTRL+P` passwords, `SUPER+CTRL+O` 2FA codes, waybar `custom/vault`, hub rows in `actions.d/u5.tsv`; logic in `scripts/vault.sh` + `vault-totp.py`). One-time `bw-setup` (asks server URL and e-mail; they live in `~/.config/rbw`, never in the repo); Hyprland runs `vault.sh session-start` (`rbw stop-agent`) at login so the master password is asked once per session. `2fa-import` converts a Google Authenticator export QR into a Bitwarden CSV on tmpfs. User commands live in `.local/bin/` (stowed per file). Copied secrets use `wl-copy --sensitive` (cliphist skips them) and are cleared after 30 s. Full Bitwarden (U6): the desktop app (`bitwarden`, Wayland via `.config/electron39-flags.conf`, floating window rule, waybar middle click) and the official CLI `bw` with hub rows in `actions.d/u6.tsv` (new login, generator, Send text/file, attachments, history, edit, delete; logic in `scripts/vault-bw.py`, session key only in `$XDG_RUNTIME_DIR/vault/bw-session`, cleared with the rbw agent at login and by lock; `bw-setup` also logs `bw` in). Opt-in SSH keys from the vault: `vault.sh ssh-agent on` (flag in `~/.local/state/vault/`) makes shells use the app's `~/.bitwarden-ssh-agent.sock` only while it exists; import a key in the app (New > SSH key), verify with `SSH_AUTH_SOCK=~/.bitwarden-ssh-agent.sock ssh-add -L`. `oo7` is in the package list only to satisfy the `bitwarden` package's `org.freedesktop.secrets` dependency.

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
