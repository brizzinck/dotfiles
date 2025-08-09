#!/bin/bash

set -e

echo "Updating system..."
sudo pacman -Syu --noconfirm

echo "Installing essential packages..."

packages=(
  alacritty # A cross-platform, GPU-accelerated terminal emulator
  android-tools # Android platform tools
  base # Minimal package set to define a basic Arch Linux installation
  base-devel  # Basic tools to build Arch Linux packages
  bash-completion # Programmable completion for the bash shell
  bluez # Daemons for the bluetooth protocol stack
  bluez-utils # Development and debugging utilities for the bluetooth protocol stack
  btop # A monitor of system resources, bpytop ported to C++
  htop # Interactive process viewer
  cmake # A cross-platform open-source make system
  clang # C language family frontend for LLVM
  cloc # Count lines of code
  cmatrix # A curses-based scrolling 'Matrix'-like screen
  curl # command line tool and library for transferring data with URLs
  dante # SOCKS v4 and v5 compatible proxy server and client
  discord # All-in-one voice and text chat for gamers
  dunst # Customizable and lightweight notification-daemon
  fail2ban # Bans IPs after too many failed authentication attempts
  git # the fast distributed version control system
  grim # Screenshot utility for Wayland
  grub # GNU GRand Unified Bootloader
  go # Core compiler tools for the Go programming language
  noto-fonts-cjk # Google Noto CJK fonts
  noto-fonts-emoji # Google Noto Color Emoji font
  obsidian # A powerful knowledge base that works on top of a local folder of plain text Markdown files
  ripgrep # A search tool that combines the usability of ag with the raw speed of grep
  fpc # Free Pascal Compiler, Turbo Pascal 7.0 and Delphi compatible.
  protobuf # Protocol Buffers - Google's data interchange format
  swaybg # Wallpaper tool for Wayland compositors
  kotlin # Statically typed programming language with multiplatform support
  lazarus # Delphi-like IDE for FreePascal common files
  hypridle # hyprland’s idle daemon
  hyprland # a highly customizable dynamic tiling Wayland compositor
  hyprlock # hyprland’s GPU-accelerated screen locking utility
  hyprpaper # a blazing fast wayland wallpaper utility with IPC controls
  imv # Image viewer for Wayland and X11
  ipset # Administration tool for IP sets
  linux # The Linux kernel and modules
  linux-firmware # Firmware files for Linux - Default set
  linux-headers # Headers and scripts for building modules for the Linux kernel
  less #  A terminal based program for viewing text files
  lld # Linker from the LLVM project
  flatpak # Linux application sandboxing and distribution framework (formerly xdg-app)
  nano # Pico editor clone with enhancements
  neovim # Fork of Vim aiming to improve user experience, plugins, and GUIs
  networkmanager # Network connection manager and user applications
  nodejs # Evented I/O for V8 javascript
  npm # JavaScript package manager
  nvidia # NVIDIA kernel modules
  nvidia-utils # NVIDIA drivers utilities
  nvidia-settings # Tool for configuring the NVIDIA graphics driver
  vulkan-icd-loader # Vulkan Installable Client Driver (ICD) Loader
  vulkan-tools # Vulkan tools and utilities
  libgl # The GL Vendor-Neutral Dispatch library
  mesa # Open-source OpenGL drivers
  obs-studio # Free, open source software for live streaming and recording
  pavucontrol # A Pulseaudio mixer in Qt (port of pavucontrol)
  pipewire # Low-latency audio/video router and processor
  pipewire-alsa # Low-latency audio/video router and processor - ALSA configuration
  pipewire-pulse # Low-latency audio/video router and processor - PulseAudio replacement
  python # The Python programming language
  python-pip # The PyPA recommended tool for installing Python packages
  ranger # Simple, vim-like file manager
  rkhunter # Checks machines for the presence of rootkits and other unwanted tools.
  rofi # A window switcher, application launcher and dmenu replacement
  seatd # A minimal seat management daemon, and a universal seat management library
  slurp # Select a region in a Wayland compositor
  snapshot # Take pictures and videos
  openssh # SSH protocol implementation for remote login, command execution and file transfer
  Telegram # Official Telegram Desktop client
  man-db # A utility for reading man pages
  tldr # Command line client for tldr, a collection of simplified man pages.
  wmctrl # Control your EWMH compliant window manager from command line
  firefox # Fast, Private & Safe Web Browser
  tree # A directory listing program displaying a depth indented list of files
  ttf-jetbrains-mono-nerd # Patched font JetBrains Mono from nerd fonts library
  ufw # Uncomplicated and easy to use CLI tool for managing a netfilter firewall
  vim # Vi Improved, a highly configurable, improved version of the vi text editor
  waybar # Highly customizable Wayland bar for Sway and Wlroots based compositors
  wireplumber # Session / policy manager implementation for PipeWire
  wofi # launcher for wlroots-based wayland compositors
  wl-clipboard # Command-line copy/paste utilities for Wayland
  docker # Pack, ship and run any application as a lightweight container 
  docker-compose # Fast, isolated development environments using Docker
  docker-buildx # Docker CLI plugin for extended build capabilities with BuildKit
  xdg-desktop-portal-hyprland # xdg-desktop-portal backend for hyprland
  yazi # Blazing fast terminal file manager written in Rust, based on async I/O
  zoxide # A smarter cd command for your terminal
  zig # a general-purpose programming language and toolchain for maintaining robust, optimal, and reusable software
  zip # Compressor/archiver for creating and modifying zipfiles
  zellij # A terminal multiplexer
  zsh # A very advanced and programmable command interpreter (shell) for UNIX
  mpv # a free, open source, and cross-platform media player
)

sudo pacman -S --noconfirm "${packages[@]}"

echo "Creating directories..."
mkdir -p ~/job ~/docs/books ~/pics/{walls,screenshots} ~/vids/screencaptures ~/.local/bin
flatpak override --user --filesystem=$HOME/downloads

echo "Installing yay..."
if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
    cd ..
    rm -rf yay-bin
fi

echo "Installing AUR packages..."
yes | yay -S --sudoloop --noconfirm ttf-jetbrains-mono-nerd facad

sudo flatpak install -y com.google.Chrome \
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
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
go install github.com/bufbuild/buf-language-server/cmd/bufls@latest

echo "Install npm packages..."
npm install next
npm install pyright
npm install sql-formatter

echo "Setting up docker..."
sudo systemctl start docker
if ! getent group docker &>/dev/null; then
  sudo groupadd docker 
fi
sudo usermod -aG docker $USER
sudo systemctl enable docker.service
sudo systemctl enable containerd.service
sudo docker buildx install

echo "Setting up Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

echo "Installing Zsh plugins..."

ZSH_CUSTOM=${ZSH_CUSTOM:-~/.oh-my-zsh/custom}
if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" ]; then
  git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions
fi
if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" ]; then
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting
fi

echo "Installing lazy..."
rm -rf -r ~/.local/share/nvim/site/pack/lazy/start/lazy.nvim
git clone https://github.com/folke/lazy.nvim.git ~/.local/share/nvim/site/pack/lazy/start/lazy.nvim

echo "Installing Rust..."
if ! command -v rustc &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

rustup component add rust-src

echo "Deleting existing dotfiles..."

CONFIG_DIR="$HOME/.config"

DIR=(
    "$CONFIG_DIR/alacritty"
    "$CONFIG_DIR/dunst"
    "$CONFIG_DIR/hypr"
    "$CONFIG_DIR/rofi"
    "$CONFIG_DIR/waybar"
    "$CONFIG_DIR/wofi"
    "$CONFIG_DIR/nvim"
    "$HOME/.gitconfig"
    "$HOME/.zshrc"
)

for dir in "${DIR[@]}"; do
    if [ -f "$dir" ]; then
        rm -r "$dir"
        echo "Deleted dir: $dir"
    else
        echo "Dir not found: $dir"
    fi
done

echo "Setting up dotfiles with Stow..."
sudo pacman -S --noconfirm stow # Manage installation of multiple softwares in the same directory tree
cd ~/dotfiles
stow .

echo "Generating SSH-KEY..."
yes | ssh-keygen -t ed25519 -C "lavrishkovlad@gmail.com" -f ~/.ssh/id_ed25519 -N "" -q
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

echo "Removing empty directories..."
find "$CONFIG_DIR" -type d -empty -delete

echo "Installation and configuration complete!"

echo "Do reboot? [Y,n]"
read input

case "$input" in 
  [Nn]) echo "Do it later!" ;;
  *) echo reboot ;;
esac
