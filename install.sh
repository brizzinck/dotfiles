#!/bin/bash

set -e  

echo "Updating system..."
sudo pacman -Syu --noconfirm

echo "Installing essential packages..."
sudo pacman -S --noconfirm \
    zathura dunst btop waybar hypridle hyprlock hyprpaper alacritty ranger rofi firefox-developer-edition chromium \
    telegram-desktop wl-clipboard grim slurp npm pnpm yarn gimp qt5ct lxappearance foliate \
    fastfetch zsh materia-gtk-theme pavucontrol zip unzip tree obs-studio audacity steam \
    imv mpv noto-fonts-cjk zig python nodejs ttf-dejavu noto-fonts-emoji kdenlive sof-firmware \
    zathura-pdf-mupdf fzf docker docker-compose alsa-utils dnsutils distrobox bluez bluez-utils cheese \
    wlogout vesktop spotify video-downloader ncdu

echo "Installing yay (AUR helper)..."
if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

echo "Installing AUR packages..."
yay -S --noconfirm ttf-jetbrains-mono-nerd

echo "Creating directories..."
mkdir -p ~/Dev
mkdir -p ~/Documents/books
mkdir -p ~/Pictures/{walls,screenshots}
mkdir -p ~/Videos/screencaptures
mkdir -p ~/.local/bin

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

echo "Installation and configuration complete!"
