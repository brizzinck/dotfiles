#!/usr/bin/env bash
# dotfiles bootstrap — Arch Linux + Hyprland + Neovim AI-agent cockpit.
# Safe to re-run: every step is idempotent. Works for any user account: nothing here
# assumes a username, home path or e-mail. Non-interactive runs (no TTY) skip the few
# prompts and print what to do by hand at the end.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
IS_TTY=0; [ -t 0 ] && IS_TTY=1
MANUAL_STEPS=()

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" &>/dev/null; }
later(){ MANUAL_STEPS+=("$*"); }

command -v pacman &>/dev/null || die "this bootstrap targets Arch Linux (pacman not found)"
[ "$(id -u)" -eq 0 ] && die "run as your normal user, not root (sudo is used where needed)"

# keep sudo alive for the whole run
sudo -v
( while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null ) &

# ───────────────────────────── 1. system packages ─────────────────────────────
log "Updating system"
sudo pacman -Syu --noconfirm

log "Installing packages"
packages=(
  # base / build
  base base-devel linux linux-firmware linux-headers grub networkmanager openssh
  git git-lfs stow curl wget less tree zip unzip man-db tldr bash-completion
  cmake clang lld zig
  # shell & terminal
  zsh tmux zellij alacritty ghostty ripgrep fd fzf jq yazi ranger zoxide btop htop
  # editors & languages
  neovim vim nano go nodejs npm python python-pip kotlin protobuf
  # wayland desktop
  hyprland hypridle hyprlock hyprpaper xdg-desktop-portal-hyprland waybar wofi rofi dunst
  swaybg grim slurp imv wl-clipboard brightnessctl wmctrl seatd
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol
  ttf-jetbrains-mono-nerd noto-fonts-cjk noto-fonts-emoji
  # graphics
  mesa libgl vulkan-icd-loader vulkan-tools imagemagick ffmpegthumbnailer
  # apps
  firefox telegram-desktop discord obsidian obs-studio mpv snapshot flatpak
  # containers & security
  docker docker-compose docker-buildx ufw fail2ban rkhunter ipset dante
  # misc
  android-tools bluez bluez-utils cloc cmatrix fpc lazarus
)
sudo pacman -S --needed --noconfirm "${packages[@]}"

# NVIDIA only when the GPU is present
if lspci 2>/dev/null | grep -qi nvidia; then
  log "NVIDIA GPU detected — installing drivers"
  sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils nvidia-settings
fi

log "Creating directories"
mkdir -p "$HOME"/{job,docs/books,pics/walls,pics/screenshots,vids/screencaptures,.local/bin,.local/state,.config}

# ───────────────────────────── 2. AUR / flatpak ───────────────────────────────
log "Installing yay"
if ! have yay; then
  tmp="$(mktemp -d)"; git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  ( cd "$tmp/yay-bin" && makepkg -si --noconfirm ); rm -rf "$tmp"
fi
yay -S --needed --noconfirm --sudoloop facad || warn "AUR install failed (facad) — continuing"

log "Flatpak apps"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
flatpak override --user --filesystem="$HOME/downloads" || true
for app in com.google.Chrome com.spotify.Client us.zoom.Zoom app.zen_browser.zen \
           org.pgadmin.pgadmin4 rest.insomnia.Insomnia com.google.AndroidStudio \
           com.valvesoftware.Steam com.mojang.Minecraft com.unity.UnityHub app.ytmdesktop.ytmdesktop; do
  sudo flatpak install -y --noninteractive flathub "$app" || warn "flatpak $app failed — continuing"
done

# ───────────────────────────── 3. toolchains ──────────────────────────────────
log "Rust"
if ! have rustc; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
rustup component add rust-src clippy rustfmt || true

log "Go tools"
export PATH="$HOME/go/bin:$PATH"
go install github.com/jesseduffield/lazygit@latest
go install github.com/jesseduffield/lazydocker@latest
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.2.1
go install golang.org/x/tools/cmd/goimports@latest
go install mvdan.cc/gofumpt@latest
go install github.com/segmentio/golines@latest
go install github.com/bombsimon/wsl/v5/cmd/wsl@latest
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
go install github.com/bufbuild/buf-language-server/cmd/bufls@latest

log "npm (user-local prefix, no sudo)"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
npm install -g sql-formatter

# ───────────────────────────── 4. AI agents ───────────────────────────────────
log "AI CLIs: Claude Code, Codex, Gemini, Copilot"
if ! have claude; then curl -fsSL https://claude.ai/install.sh | bash; fi
export PATH="$HOME/.local/bin:$PATH"
npm install -g @openai/codex @google/gemini-cli @github/copilot

log "Agent cockpit backends: mcp-hub, ACP adapters, workmux"
npm install -g mcp-hub@latest @agentclientprotocol/claude-agent-acp @zed-industries/codex-acp
have workmux || cargo install workmux

# ───────────────────────────── 5. shell ───────────────────────────────────────
log "Oh My Zsh + plugins"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
[ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]     || git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
[ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ] || git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
if [ "$SHELL" != "$(command -v zsh)" ]; then
  chsh -s "$(command -v zsh)" || warn "chsh failed — run: chsh -s $(command -v zsh)"
fi

# ───────────────────────────── 6. docker ──────────────────────────────────────
log "Docker"
sudo systemctl enable --now docker.service containerd.service || warn "docker service not started"
getent group docker >/dev/null || sudo groupadd docker
sudo usermod -aG docker "$USER"

# ───────────────────────────── 7. dotfiles (stow) ─────────────────────────────
log "Linking dotfiles with stow (existing files are moved to $BACKUP_DIR)"
cd "$DOTFILES"
git submodule update --init --recursive
# Move real files/dirs out of the way; leave symlinks (stow manages them)
while IFS= read -r rel; do
  target="$HOME/$rel"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    mv "$target" "$BACKUP_DIR/$rel"
    echo "  backed up $rel"
  fi
done < <(cd "$DOTFILES" && find . -mindepth 1 -maxdepth 2 \
           \( -path './.git*' -o -path './.config' -o -name 'README*' -o -name 'LICENSE*' -o -name 'CLAUDE.md' \
              -o -name 'install.sh' -o -name 'flash.sh' -o -name 'env.secret.sh' -o -path './infrastructure*' \
              -o -path './themes*' -o -path './node_modules*' -o -name 'package*.json' -o -name '.stow-local-ignore' \
              -o -path './private*' \) -prune -o -print \
         | sed 's|^\./||' | awk -F/ 'NF<=2')
stow --restow .
# private submodule (secrets, machine-local configs) — stowed separately, skipped if not cloned
if [ -d "$DOTFILES/private" ] && [ -n "$(ls -A "$DOTFILES/private" 2>/dev/null)" ]; then
  (cd "$DOTFILES/private" && stow --restow .)
fi
touch "$DOTFILES/env.secret.sh" && chmod +x "$DOTFILES/env.secret.sh"

# ───────────────────────────── 8. identity ────────────────────────────────────
log "Git identity (~/.gitconfig.local)"
GIT_NAME="${GIT_USER_NAME:-$(git config --global --includes user.name 2>/dev/null || true)}"
GIT_EMAIL="${GIT_USER_EMAIL:-$(git config --global --includes user.email 2>/dev/null || true)}"
if [ "$IS_TTY" = 1 ]; then
  read -rp "  git user.name  [${GIT_NAME:-required}]: " in; GIT_NAME="${in:-$GIT_NAME}"
  read -rp "  git user.email [${GIT_EMAIL:-required}]: " in; GIT_EMAIL="${in:-$GIT_EMAIL}"
fi
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
  printf '[user]\n\tname = %s\n\temail = %s\n' "$GIT_NAME" "$GIT_EMAIL" > "$HOME/.gitconfig.local"
else
  later "set your git identity: printf '[user]\\n\\tname = NAME\\n\\temail = MAIL\\n' > ~/.gitconfig.local"
fi

log "SSH key"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "${GIT_EMAIL:-$USER@$(hostname)}" -f "$HOME/.ssh/id_ed25519" -N "" -q
  later "add ~/.ssh/id_ed25519.pub to GitHub/GitLab: cat ~/.ssh/id_ed25519.pub"
fi

# ───────────────────────────── 9. tmux ────────────────────────────────────────
log "tmux plugins (TPM)"
[ -d "$HOME/.tmux/plugins/tpm" ] || git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
"$HOME/.tmux/plugins/tpm/bin/install_plugins" || warn "TPM plugin install failed — press prefix+I inside tmux"

# ───────────────────────────── 10. neovim ─────────────────────────────────────
log "Neovim: plugins, Mason tools, treesitter parsers, agent hooks (headless, a few minutes)"
nvim --headless -c "luafile $HOME/.config/nvim/scripts/bootstrap.lua" 2>&1 | grep -v '^$' || warn "nvim bootstrap reported errors — open nvim and run :Lazy restore, :MasonInstallAll, :AgentDashInstallHooks"

# ───────────────────────────── 11. agents ↔ MCP hub / worktrees ──────────────
log "Registering the MCP hub with Claude Code and Codex"
if have claude && ! claude mcp get mcphub &>/dev/null; then
  claude mcp add -s user --transport http mcphub http://localhost:37373/mcp || warn "claude mcp add failed"
fi
if have codex && ! grep -q 'mcp_servers.mcphub' "$HOME/.codex/config.toml" 2>/dev/null; then
  codex mcp add mcphub --url http://localhost:37373/mcp || warn "codex mcp add failed"
fi

log "workmux agent status hooks"
if [ "$IS_TTY" = 1 ]; then
  workmux setup --hooks || warn "workmux setup failed"
else
  later "run once in a terminal: workmux setup --hooks"
fi

# ───────────────────────────── 12. done ───────────────────────────────────────
find "$HOME/.config" -maxdepth 1 -type d -empty -delete 2>/dev/null || true
later "log in to the agents: claude   |   codex login   |   gemini   |   copilot"
later "GitHub Copilot LSP (Next Edit Suggestions): open nvim, follow the sign-in notice, then :checkhealth sidekick"
later "start working: ta   (tmux)  →  nvim  →  <leader>ac (Claude) / <leader>ax (Codex) / <leader>ad (agent dashboard)"

log "Installation complete"
if [ ${#MANUAL_STEPS[@]} -gt 0 ]; then
  printf '\nManual steps left:\n'; for s in "${MANUAL_STEPS[@]}"; do printf '  • %s\n' "$s"; done
fi
[ -d "$BACKUP_DIR" ] && printf '\nPrevious configs were moved to %s\n' "$BACKUP_DIR"

if [ "$IS_TTY" = 1 ]; then
  read -rp $'\nReboot now? [y/N] ' input
  case "$input" in [Yy]) exec sudo reboot ;; *) echo "Reboot later to finish (docker group, shell, drivers)." ;; esac
fi
