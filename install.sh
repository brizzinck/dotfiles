#!/bin/bash

set -e

echo "Updating system..."
sudo pacman -Syu --noconfirm

echo "Installing essential packages..."

sudo pacman -S --noconfirm \
  alacritty \
  base \
  base-devel \
  bash-completion \
  bluez \
  bluez-utils \
  brightnessctl \
  cmake \
  cronie \
  dante \
  discord \
  dunst \
  fail2ban \
  geoipupdate \
  git \
  github-desktop-bin \
  github-desktop-bin-debug \
  grim \
  grub \
  hypridle \
  hyprland \
  hyprlock \
  hyprpaper \
  imv \
  ipset \
  lazygit \
  lib32-gcc-libs \
  linux \
  linux-firmware \
  linux-headers \
  lld \
  lxappearance \
  materia-gtk-theme \
  mesa-utils \
  nano \
  neofetch \
  neovim \
  networkmanager \
  nodejs \
  npm \
  noto-fonts-cjk \
  noto-fonts-emoji \
  nvidia \
  nvidia-settings \
  obs-studio \
  pavucontrol \
  pipewire \
  pipewire-alsa \
  pipewire-pulse \
  polkit-kde-agent \
  python \
  python-pip \
  qps \
  qt5ct \
  ranger \
  rkhunter \
  rofi \
  screengrab \
  seatd \
  slurp \
  snapshot \
  spotify \
  steam \
  swappy \
  tecla \
  telegram-desktop \
  tree \
  ttf-dejavu \
  ttf-hack \
  ttf-jetbrains-mono-nerd \
  ttf-opensans \
  ttf-ubuntu-font-family \
  ufw \
  vesktop \
  video-downloader \
  vim \
  waybar \
  wl-clipboard \
  wlroots \
  wlogout \
  wireplumber \
  wofi \
  xdg-desktop-portal-hyprland \
  yazi \
  yay \
  yay-debug \
  zathura \
  zathura-pdf-mupdf \
  zig \
  zsh

echo "Installing yay (AUR helper)..."
if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

echo "Installing AUR packages..."
yay -S --noconfirm ttf-jetbrains-mono-nerd github-desktop-bin

flatpak install -y com.google.Chrome \
    com.mojang.Minecraft \
    com.spotify.Client \
    us.zoom.Zoom

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

echo "Installing Astro Nvim..."
git clone --depth 1 https://github.com/AstroNvim/template ~/.config/nvim
rm -rf ~/.config/nvim/.git

echo "Setting up dotfiles with Stow..."
sudo pacman -S --noconfirm stow
cd ~/dotfiles
stow .

echo "Installation and configuration complete!"
