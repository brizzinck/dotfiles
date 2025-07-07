#!/bin/bash

set -e

echo "Updating system..."
sudo pacman -Syu --noconfirm

echo "Installing essential packages..."

sudo pacman -S --noconfirm \
  alacritty \ # A cross-platform, GPU-accelerated terminal emulator
  android-sdk \ # Google Android SDK
  android-tools \ # Android platform tools
  base \ # Minimal package set to define a basic Arch Linux installation
  base-devel \ # Basic tools to build Arch Linux packages
  bash-completion \ # Programmable completion for the bash shell
  bluez \ # Daemons for the bluetooth protocol stack
  bluez-utils \ # Development and debugging utilities for the bluetooth protocol stack
  cmake \ # A cross-platform open-source make system
  dante \ # SOCKS v4 and v5 compatible proxy server and client
  discord \ # All-in-one voice and text chat for gamers
  dunst \ # Customizable and lightweight notification-daemon
  fail2ban \ # Bans IPs after too many failed authentication attempts
  git \ # the fast distributed version control system
  grim \ # Screenshot utility for Wayland
  grub \ # GNU GRand Unified Bootloader
  go \ # Core compiler tools for the Go programming language
  obsidian \ # A powerful knowledge base that works on top of a local folder of plain text Markdown files
  hypridle \ # hyprland’s idle daemon
  hyprland \ # a highly customizable dynamic tiling Wayland compositor
  hyprlock \ # hyprland’s GPU-accelerated screen locking utility
  hyprpaper \ # a blazing fast wayland wallpaper utility with IPC controls
  imv \ # Image viewer for Wayland and X11
  ipset \ # Administration tool for IP sets
  lib32-gcc-libs \
  linux \ # The Linux kernel and modules
  linux-firmware \ # Firmware files for Linux - Default set
  linux-headers \ # Headers and scripts for building modules for the Linux kernel
  lld \ # Linker from the LLVM project
  nano \ # Pico editor clone with enhancements
  neofetch \ # A CLI system information tool written in BASH that supports displaying images.
  neovim \ # Fork of Vim aiming to improve user experience, plugins, and GUIs
  networkmanager \ # Network connection manager and user applications
  nodejs \ # Evented I/O for V8 javascript
  npm \ # JavaScript package manager
  nvidia \ # NVIDIA kernel modules
  obs-studio \ # Free, open source software for live streaming and recording
  pavucontrol \ # A Pulseaudio mixer in Qt (port of pavucontrol)
  pipewire \ # Low-latency audio/video router and processor
  pipewire-alsa \ # Low-latency audio/video router and processor - ALSA configuration
  pipewire-pulse \ # Low-latency audio/video router and processor - PulseAudio replacement
  python \ # The Python programming language
  python-pip \ # The PyPA recommended tool for installing Python packages
  ranger \ # Simple, vim-like file manager
  rkhunter \ # Checks machines for the presence of rootkits and other unwanted tools.
  rofi \ # A window switcher, application launcher and dmenu replacement
  seatd \ # A minimal seat management daemon, and a universal seat management library
  slurp \ # Select a region in a Wayland compositor
  snapshot \ # Take pictures and videos
  telegram-desktop \ # Official Telegram Desktop client
  tree \ # A directory listing program displaying a depth indented list of files
  ttf-jetbrains-mono-nerd \ # Patched font JetBrains Mono from nerd fonts library
  ufw \ # Uncomplicated and easy to use CLI tool for managing a netfilter firewall
  vim \ # Vi Improved, a highly configurable, improved version of the vi text editor
  waybar \ # Highly customizable Wayland bar for Sway and Wlroots based compositors
  wireplumber \ # Session / policy manager implementation for PipeWire
  wofi \ # launcher for wlroots-based wayland compositors
  docker \ # Pack, ship and run any application as a lightweight container 
  docker-compose \ # Fast, isolated development environments using Docker
  xdg-desktop-portal-hyprland \ # xdg-desktop-portal backend for hyprland
  yazi \ # Blazing fast terminal file manager written in Rust, based on async I/O
  zoxide \ # A smarter cd command for your terminal
  zig \ # a general-purpose programming language and toolchain for maintaining robust, optimal, and reusable software
  zsh # A very advanced and programmable command interpreter (shell) for UNIX

echo "Installing yay..."
if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

echo "Installing AUR packages..."
yay -S --noconfirm ttf-jetbrains-mono-nerd facad

flatpak install -y com.google.Chrome \
    com.mojang.Minecraft \
    com.spotify.Client \
    us.zoom.Zoom \
    app.zen_browser.zen \
    com.google.AndroidStudio \
    com.unity.UnityHub \
    com.valvesoftware.Steam \
    org.pgadmin.pgadmin4 \
    rest.insomnia.Insomnia

echo "Installing Go packages..."
go install github.com/jesseduffield/lazygit@latest
go install github.com/jesseduffield/lazydocker@latest
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.2.1

echo "Setting up docker..."
modprobe kvm
modprobe kvm_amd
sudo usermod -aG kvm $USER

echo "Creating directories..."
mkdir -p ~/job ~/docs/books ~/pics/{walls,screenshots} ~/vids/screencaptures ~/.local/bin

echo "Setting up Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

echo "Installing Zsh plugins..."
ZSH_CUSTOM=${ZSH_CUSTOM:-~/.oh-my-zsh/custom}
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting

echo "Installing Rust..."
if ! command -v rustc &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

echo "Deleting existing dotfiles..."

CONFIG_DIR="$HOME/.config"

FILES=(
    "$CONFIG_DIR/alacritty/alacritty.toml"
    "$CONFIG_DIR/dunst/dunstrc"
    "$CONFIG_DIR/hypr/hypridle.conf"
    "$CONFIG_DIR/hypr/hyprland.conf"
    "$CONFIG_DIR/hypr/hyprlock.conf"
    "$CONFIG_DIR/hypr/hyprpaper.conf"
    "$CONFIG_DIR/nvim/lua/plugins/user.lua"
    "$CONFIG_DIR/rofi/config.rasi"
    "$CONFIG_DIR/waybar/config"
    "$CONFIG_DIR/waybar/style.css"
    "$CONFIG_DIR/wofi/config"
    "$CONFIG_DIR/wofi/style.css"
    "$CONFIG_DIR/nvim"
    "$HOME/.gitconfig"
    "$HOME/.zshrc"
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        rm -r "$file"
        echo "Deleted file: $file"
    else
        echo "File not found: $file"
    fi
done

echo "Removing empty directories..."
find "$CONFIG_DIR" -type d -empty -delete

echo "Setting up dotfiles with Stow..."
sudo pacman -S --noconfirm stow # Manage installation of multiple softwares in the same directory tree
cd ~/dotfiles
stow .


echo "Installation and configuration complete!"
