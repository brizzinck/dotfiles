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
  cmake clang lld
  # shell & terminal
  zsh tmux zellij alacritty ghostty ripgrep fd fzf jq yazi ranger zoxide btop htop
  # editors & languages
  neovim vim nano go nodejs npm python python-pip protobuf
  # wayland desktop
  hyprland hypridle hyprlock hyprpaper xdg-desktop-portal-hyprland xdg-desktop-portal-gtk waybar wofi rofi dunst
  swaybg grim slurp swappy imv wl-clipboard brightnessctl seatd
  nemo libnotify xdg-utils xdg-user-dirs qt6ct   # hyprland.lua: fileManagerGUI, notify-send, xdg-open, QT_QPA_PLATFORMTHEME (qt6ct)
  pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol
  easyeffects noise-suppression-for-voice lsp-plugins lsp-plugins-lv2
  ttf-jetbrains-mono-nerd noto-fonts-cjk noto-fonts-emoji
  # graphics
  mesa libgl vulkan-icd-loader vulkan-tools imagemagick ffmpeg ffmpegthumbnailer ueberzugpp yt-dlp
  # apps
  firefox telegram-desktop discord obsidian obs-studio mpv snapshot flatpak
  # containers & security
  docker docker-compose docker-buildx ufw fail2ban rkhunter ipset dante
  # power management
  tlp
  # misc
  android-tools bluez bluez-utils cloc cmatrix
  # workstation additions — keep in sync with REPO_PACKAGES in apply-system.sh (it verifies each name with pacman -Si)
  pacman-contrib earlyoom reflector smartmontools nvme-cli libva-utils amdgpu_top   # paccache/updates, OOM guard, mirrors, SMART, vainfo, GPU monitor
  hyprpolkitagent cliphist wl-clip-persist swayosd wiremix hyprshot satty hyprpicker hyprsunset
  xorg-xcursorgen librsvg                                                           # build deps of the local everforest-cursor-theme package (infrastructure/cursor)
  rofimoji wtype udiskie                                                            # polkit agent, clipboard, OSD, screenshots, picker, emoji (rofimoji = the emoji data of emoji.sh), automount
  bat eza git-delta github-cli trash-cli dust duf watchexec just go-yq xh shfmt direnv dive hyperfine
  tesseract tesseract-data-eng tesseract-data-rus zbar qrencode ddcutil pik                       # OCR (rus+eng), QR, DDC/CI monitor brightness, ports
  libqalculate chafa gifski kondo lostfiles termdown bandwhich lsof                           # calculator, image previews (chafa: kitty graphics in fzf-menu), GIF, cleanup, timer, network, open files
  tlp-pd                                                                                          # TLP profiles daemon (tlpctl), conflicts with power-profiles-daemon
  rbw kwindowsystem                                                                      # Bitwarden/Vaultwarden client (fzf-menu front end); kwindowsystem = pinentry-qt backend
  oo7 bitwarden                                                                                   # Bitwarden desktop (the bw CLI is AUR bitwarden-cli-bin); oo7 only satisfies the desktop package's org.freedesktop.secrets dependency (see apply-system.sh)
  greetd greetd-tuigreet quickshell                                                                # login screen (infrastructure/greetd): greetd + Quickshell greeter, tuigreet fallback; enabled by apply-system.sh --only greeter
)
sudo pacman -S --needed --noconfirm "${packages[@]}"

# CPU microcode matching the vendor (grub-mkconfig, run by apply-system.sh, adds the ucode image to the boot entries)
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  sudo pacman -S --needed --noconfirm amd-ucode
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
  sudo pacman -S --needed --noconfirm intel-ucode
fi

log "Creating directories"
mkdir -p "$HOME"/{job,docs/books,pics/walls,pics/screenshots,Downloads,Videos/screencaptures,.local/bin,.local/state,.config}

# ───────────────────────────── 2. AUR / flatpak ───────────────────────────────
log "Installing yay"
if ! have yay; then
  tmp="$(mktemp -d)"; git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
  ( cd "$tmp/yay-bin" && makepkg -si --noconfirm ); rm -rf "$tmp"
fi
# hyprdynamicmonitors-bin: /usr/bin/hyprdynamicmonitors for infrastructure/systemd units (enable by hand, see CLAUDE.md)
# bibata-cursor-theme-bin: Bibata-Modern-Ice cursor theme; shellcheck-bin: static build that replaces the repo package
# (no haskell chain); ccusage: Claude/Codex usage from local logs; wayscrollshot-bin: scrolling screenshots;
# pacseek: pacman/AUR TUI; bitwarden-cli-bin: bw CLI (the repo bitwarden-cli needs nodejs-lts-jod, which conflicts with nodejs);
# wlrctl: keyboard-driven pointer (SUPER+', SUPER+ALT+M, with wl-kbptr below); wlr-which-key: the SUPER+; leader menu;
# tmux-fingers: prefix f hints in tmux (built from source, no curl installer); obs-cmd: OBS by keyboard (leader o);
# voxtype-bin: offline dictation (SUPER+ALT+D, F9); downgrade: pacman cache rollback (hub Update group).
# Keep in sync with AUR_PACKAGES in apply-system.sh.
for pkg in facad hyprdynamicmonitors-bin bibata-cursor-theme-bin shellcheck-bin ccusage wayscrollshot-bin pacseek bitwarden-cli-bin wlrctl wlr-which-key tmux-fingers obs-cmd voxtype-bin downgrade; do
  yay -S --needed --noconfirm --sudoloop "$pkg" || warn "AUR install failed ($pkg) — continuing"
done
yay --save --cleanafter >/dev/null 2>&1 || true   # remove AUR build dirs after each install

# the Everforest pointer: local package (infrastructure/cursor/PKGBUILD, hyprcursor SVG + XCursor, colours from the palette),
# built here with makepkg and installed with pacman -U so every app and flatpak sees it in /usr/share/icons; skipped when current.
# Bibata (above) stays installed as the fallback. Same build as `sudo ./apply-system.sh --only install`.
log "Everforest cursor (local package)"
"$DOTFILES/infrastructure/cursor/build.sh" --install || warn "Everforest cursor build failed — the pointer stays Bibata"

# wl-kbptr: local PKGBUILD without opencv (infrastructure/aur/wl-kbptr; the AUR one needs opencv4, Arch ships opencv 5)
log "wl-kbptr (local package, no opencv)"
sudo pacman -S --needed --asdeps --noconfirm meson wayland-protocols cairo wayland libxkbcommon pixman || true
"$DOTFILES/infrastructure/aur/wl-kbptr/build.sh" --install || warn "wl-kbptr build failed — SUPER+' and the mouse mode will not work"

log "Flatpak apps"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
DOWNLOADS_DIR="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"; DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Downloads}"   # XDG download dir (~/Downloads)
flatpak override --user --filesystem="$DOWNLOADS_DIR" || true
for app in com.google.Chrome com.brave.Browser com.spotify.Client us.zoom.Zoom app.zen_browser.zen \
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
have tree-sitter || cargo install tree-sitter-cli   # nvim-treesitter (main branch) compiles parsers with it

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
go install github.com/vektra/mockery/v3@latest
go install github.com/swaggo/swag/cmd/swag@latest
go install golang.org/x/vuln/cmd/govulncheck@latest
go install gotest.tools/gotestsum@latest
# YaCodeDev tooling (private GitHub org, needs SSH access) — used by the agent skills in private/
# SSH rewrite is passed per-command via GIT_CONFIG_* so ~/.gitconfig (stowed from this repo) stays untouched.
if [ -d "$DOTFILES/private/.claude" ]; then
  for tool in yagolint yagocodegen yaagentmanager; do
    GOPRIVATE=github.com/YaCodeDev GONOSUMDB=github.com/YaCodeDev \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.git@github.com:YaCodeDev/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/YaCodeDev/" \
      go install "github.com/YaCodeDev/YaCodeDevTools/$tool@latest" \
      || warn "go install $tool failed — needs SSH read access to github.com/YaCodeDev/YaCodeDevTools"
  done
fi

log "npm (user-local prefix, no sudo)"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
npm install -g sql-formatter

# ───────────────────────────── 4. AI agents ───────────────────────────────────
log "AI CLIs: Claude Code, Codex, Gemini"
if ! have claude; then curl -fsSL https://claude.ai/install.sh | bash; fi
export PATH="$HOME/.local/bin:$PATH"
npm install -g @openai/codex @google/gemini-cli

log "RTK (bash output compressor for LLM tools)"
if ! have rtk; then curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh; fi
export PATH="$HOME/.local/bin:$PATH"
if have rtk; then rtk init -g || warn "rtk init failed — run manually: rtk init -g"; fi

log "Agent cockpit backends: mcp-hub, ACP adapters, workmux"
npm install -g mcp-hub@latest @agentclientprotocol/claude-agent-acp @zed-industries/codex-acp
# MCP servers as pinned global binaries (no `npx …@latest` wrapper process / registry round-trip on every agent start)
npm install -g chrome-devtools-mcp@1.11.0 mcp-remote@0.14.3
have workmux || cargo install workmux

# ───────────────────────────── 5. shell ───────────────────────────────────────
log "Oh My Zsh + plugins"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
[ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]     || git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
[ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ] || git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
[ -d "$ZSH_CUSTOM/plugins/fzf-tab" ]                 || git clone https://github.com/Aloxaf/fzf-tab "$ZSH_CUSTOM/plugins/fzf-tab"
if [ "$SHELL" != "$(command -v zsh)" ]; then
  chsh -s "$(command -v zsh)" || warn "chsh failed — run: chsh -s $(command -v zsh)"
fi

# ───────────────────────────── 6. docker ──────────────────────────────────────
log "Docker"
sudo systemctl enable --now docker.service containerd.service || warn "docker service not started"

log "Bluetooth"
sudo systemctl enable --now bluetooth.service || warn "bluetooth service not started"

log "Configuring battery charge thresholds (TLP)"
sudo cp "$DOTFILES/infrastructure/tlp/61-battery-care.conf" /etc/tlp.d/61-battery-care.conf
sudo systemctl enable --now tlp.service
sudo systemctl restart tlp.service
getent group docker >/dev/null || sudo groupadd docker
sudo usermod -aG docker "$USER"

log "Memory safety net (zram, sysctl, journald limits)"
sudo "$DOTFILES/apply-memory.sh" || warn "memory safety net not applied"

log "System layer (earlyoom, docker GC cap, pacman hooks, TLP, coredump limits, timers, GRUB)"
# apply-system.sh is idempotent; here only the sections that are safe on a fresh machine run.
# Not run here: upgrade/install/remove (handled above or by the owner), disk (tune2fs + fstab).
for section in config services users boot; do
  sudo "$DOTFILES/apply-system.sh" --only "$section" || warn "apply-system.sh --only $section failed"
done
later "optional: sudo $DOTFILES/apply-system.sh --only disk   (reserved blocks 1%, noatime,lazytime on /), --only remove (snap stack, unused toolchains, orphans)"

# ───────────────────────────── 7. dotfiles (stow) ─────────────────────────────
log "Linking dotfiles with stow (existing files are moved to $BACKUP_DIR)"
cd "$DOTFILES"
# Real directories first, so stow links single files instead of folding the whole directory:
# systemd ignores a symlinked drop-in directory, and `systemctl --user enable` would write its *.wants links into the repo.
# GTK dirs stay real (apps keep bookmarks etc. there); only settings.ini / gtk.css are linked
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
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
              -o -path './private*' -o -path './pkg*' -o -name 'apply-*.sh' \
              -o -path './browsers*' -o -path './docs*' -o -name 'doctor.sh' \) -prune -o -print \
         | sed 's|^\./||' | awk -F/ 'NF<=2')
stow --restow .
# commit hook: every commit/merge/rewrite publishes the committed state to /srv/dotfiles for the managed users (usr sync)
git -C "$DOTFILES" config core.hooksPath .githooks
# private submodule (secrets, machine-local configs) — stowed separately, skipped if not cloned
if [ -d "$DOTFILES/private" ] && [ -n "$(ls -A "$DOTFILES/private" 2>/dev/null)" ]; then
  (cd "$DOTFILES/private" && stow --restow .)
fi
touch "$DOTFILES/env.secret.sh" && chmod +x "$DOTFILES/env.secret.sh"
# palette variant link (black by default; flip with `theme black|night`): ghostty, tmux, fzf, delta and nvim read it
"$HOME/.local/bin/theme" init || warn "theme init failed (themes/generated missing?)"
# waybar bar mode (compact/full) and visibility files; the bar config includes them
"$HOME/.config/waybar/scripts/bar.sh" init || warn "bar.sh init failed (waybar scripts not stowed?)"

log "GTK dark theme, icons, fonts and cursor (gsettings; the cursor is Everforest-Cursor once installed, else Bibata, else Adwaita)"
cursor_theme=Bibata-Modern-Ice
[ -r /usr/share/icons/Everforest-Cursor/index.theme ] && cursor_theme=Everforest-Cursor
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
  gsettings set org.gnome.desktop.interface accent-color 'green' || true   # libadwaita apps that ignore gtk.css (closest enum to the palette green)
  gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || true
  gsettings set org.gnome.desktop.interface icon-theme 'breeze-dark' || true
  gsettings set org.gnome.desktop.interface monospace-font-name 'JetBrainsMono Nerd Font 11' || true
  gsettings set org.gnome.desktop.interface cursor-theme "$cursor_theme" || true
  gsettings set org.gnome.desktop.interface cursor-size 32 || true
else
  later "set GTK dark theme: gsettings set org.gnome.desktop.interface color-scheme prefer-dark (and gtk-theme Adwaita-dark, icon-theme breeze-dark, cursor-theme Everforest-Cursor, cursor-size 32)"
fi
fc-cache -f 2>/dev/null || true

log "Browser settings (Zen user.js memory prefs, Chrome disk-cache flag; copied into the flatpak sandboxes)"
"$DOTFILES/browsers/apply.sh" || warn "browsers/apply.sh failed"

log "Obsidian (vault .obsidian -> apps/obsidian/vault-config, pinned plugins from GitHub, Everforest snippet, vimrc)"
"$DOTFILES/apps/obsidian/apply.sh" || warn "apps/obsidian/apply.sh failed"

log "User timers: cache aging (user tmpfiles), Codex release pruning and the sysalert health check and the background update check (sysup-check)"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now systemd-tmpfiles-clean.timer codex-prune-releases.timer sysalert.timer sysup-check.timer hypridle-watch.timer crash-watch.service voxtype.service 2>/dev/null \
  || later "enable the user timers once logged in: systemctl --user enable --now systemd-tmpfiles-clean.timer codex-prune-releases.timer sysalert.timer sysup-check.timer hypridle-watch.timer crash-watch.service voxtype.service"

# Dictation (Voxtype, AUR voxtype-bin from the root script): the Whisper model is a user-level download (about 466 MB, resumable)
if command -v voxtype >/dev/null 2>&1; then
  log "Dictation: Whisper model for Voxtype"
  "$DOTFILES/.config/hypr/scripts/dictation.sh" model || later "dictation model: ~/.config/hypr/scripts/dictation.sh model"
fi

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
  ssh-keygen -t ed25519 -C "${GIT_EMAIL:-$USER@$(uname -n)}" -f "$HOME/.ssh/id_ed25519" -N "" -q
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
if have claude && ! claude mcp get chrome-devtools &>/dev/null; then
  claude mcp add -s user chrome-devtools -- "$HOME/.npm-global/bin/chrome-devtools-mcp" --autoConnect \
    --userDataDir "$HOME/.var/app/com.google.Chrome/config/google-chrome" --no-usage-statistics || warn "claude mcp add chrome-devtools failed"
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
later "log in to the agents: claude   |   codex login   |   gemini"
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
