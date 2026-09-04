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

`install.sh` does a full machine bootstrap: pacman packages, AUR (via yay), Flatpak apps, Go/NPM/Rust toolchains, Oh My Zsh, Docker setup, SSH key generation, then runs `stow .` to link the dotfiles.

After modifying dotfiles, re-apply with:
```bash
cd ~/dotfiles && stow .
```

## Architecture

### Config layout
All configs live under `.config/` following XDG Base Dir. Root-level files (`.zshrc`, `.gitconfig`) stow directly to `$HOME`.

### Monitor management
Two layers:
1. `.config/hypr/monitors.conf` — static Hyprland monitor declarations (resolution, scale, position)
2. `.config/kanshi/config` — dynamic profiles that override monitor state based on what's connected (e.g. disable `eDP-1` when `HDMI-A-1` is present). Kanshi is started via `exec-once = kanshi` in `hyprland.conf`.

### Theme system
`themes/static/` — pre-built color schemes (rose-pine, dracula, catppuccin-mocha, etc.), each with a `theme.toml` for HyprDynamicMonitors.  
`themes/templates/` — dynamic generators: `matugen/` (Material You), `wallust/`, `pywal/` (both wallpaper-based extraction).

### Neovim
`.config/nvim/` is a git submodule pointing to a custom NvChad fork. Update with `git submodule update --remote`.

### Infrastructure
`infrastructure/systemd/` — systemd user services for `hyprdynamicmonitors` (automatic monitor config daemon). Install with `systemctl --user enable --now hyprdynamicmonitors.service`.

### Shell aliases (`.zshrc`)
- `gtx` navigation: `gtj`=~/job, `gtd`=~/dotfiles, `gtn`=~/.config/nvim
- Git: `gs`, `ga`, `gcm`, `gp`, `gl`, etc.
- Go: `tg` (test all), `lg` (lint+tidy), `rg()` (smart run, finds main.go)
- Rust/Cargo: `rr`=run, `rc`=clippy, `of()` (fmt with edition flag)

## AI agent cockpit (Neovim + tmux)

`install.sh` is idempotent and user-agnostic: no usernames, home paths or e-mails are hardcoded.
Git identity lives in `~/.gitconfig.local` (written by `install.sh`, included from `.gitconfig`).
After `stow .` it runs `.config/nvim/scripts/bootstrap.lua` headless, which restores plugins from
`lazy-lock.json`, installs Mason tools and treesitter parsers, and writes the agent hooks
(`:AgentDashInstallHooks`) into `~/.claude/settings.json` / `~/.codex/hooks.json` with backups.

Neovim side (`lua/plugins/ai/*.lua`, all keys under `<leader>a`):
- `sidekick.nvim` — Claude/Codex/Gemini/Copilot CLIs in persistent tmux windows, context prompts, Copilot NES (`<Tab>` in normal mode)
- `claudecode.nvim` (server-only) — Claude Code IDE bridge: native diff accept/deny, `@`-mentions
- `agentic.nvim` — ACP quick chat (`claude-agent-acp`, `codex-acp`)
- `code-preview.nvim` — agent edits shown as a diff before they hit disk
- `codediff.nvim` + `review.nvim` — post-hoc review, comments sent back to the agent
- `mcphub.nvim` — one MCP endpoint (`localhost:37373`) shared by all agents; servers in `.config/mcphub/servers.json`
- `lua/agentdash/` — custom dashboard of sessions/subagents/tasks fed by agent hooks (`:AgentDash`, statusline segment)
- `workmux` (`.config/workmux/config.yaml`) — git worktree + tmux window per agent task, `<leader>aw*`

Installing new nvim plugins: use `nvim --headless "+Lazy! install" +qa`, never `Lazy sync`/`clean`
(they bump every pinned commit in `lazy-lock.json`).
