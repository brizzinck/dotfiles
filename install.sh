#!/bin/bash

set -e

echo "Updating system..."
sudo pacman -Syu --noconfirm

echo "Installing essential packages..."

sudo pacman -S --noconfirm accerciser alltray baobab base base-devel bash-completion bluez bluez-utils  \
    celluloid cheese cmake cronie d-spy dante dconf-editor devhelp discord dunst  \
    efibootmgr endeavour eog epiphany evince evolution fail2ban file-roller \
    firefox firefox-developer-edition gdm geary geoipupdate ghex git gitg  \
    github-desktop-bin github-desktop-bin-debug glade gnome-2048 \
    gnome-backgrounds gnome-boxes gnome-browser-connector gnome-builder \
    gnome-calculator gnome-calendar gnome-characters gnome-chess gnome-clocks \
    gnome-color-manager gnome-connections gnome-console gnome-contacts \
    gnome-control-center gnome-devel-docs gnome-dictionary gnome-disk-utility \
    gnome-font-viewer gnome-games gnome-keyring gnome-klotski gnome-logs \
    gnome-mahjongg gnome-maps gnome-menus gnome-mines gnome-multi-writer \
    gnome-music gnome-nibbles gnome-notes gnome-photos gnome-recipes \
    gnome-remote-desktop gnome-session gnome-settings-daemon gnome-shell \
    gnome-shell-extension-appindicator gnome-shell-extension-desktop-icons-ng \
    gnome-shell-extensions gnome-software gnome-sound-recorder gnome-sudoku \
    gnome-system-monitor gnome-taquin gnome-terminal gnome-tetravex \
    gnome-text-editor gnome-themes-extra gnome-tour gnome-tweaks gnome-user-docs \
    gnome-user-share gnome-weather grilo-plugins grim grub gvfs gvfs-afc \
    gvfs-dnssd gvfs-goa gvfs-google gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-onedrive \
    gvfs-smb gvfs-wsdd hitori hypridle hyprland hyprlock hyprpaper iagno imv \
    ipset kitty lazygit lib32-gcc-libs lightsoff linux linux-firmware \
    linux-headers lld loupe lxappearance lximage-qt lxqt-about lxqt-admin \
    lxqt-archiver lxqt-config lxqt-globalkeys lxqt-notificationd \
    lxqt-openssh-askpass lxqt-panel lxqt-policykit lxqt-powermanagement \
    lxqt-qtplugin lxqt-runner lxqt-session lxqt-sudo lxqt-themes malcontent \
    materia-gtk-theme mesa-utils nano nautilus nemo neofetch neovim \
    networkmanager nodejs npm noto-fonts-cjk noto-fonts-emoji nvidia \
    nvidia-settings obconf-qt obs-studio openbox orca pavucontrol \
    pavucontrol-qt pcmanfm-qt polari polkit-kde-agent python python-pip qps \
    qterminal quadrapassel ranger rkhunter rofi rygel screengrab sddm seahorse \
    shotwell simple-scan slurp snapshot spotify steam sushi swappy sysprof \
    tali tecla telegram-desktop thunar totem tree ttf-dejavu ttf-hack \
    ttf-jetbrains-mono-nerd ttf-opensans ttf-ubuntu-font-family ufw vesktop \
    video-downloader vim waybar wlogout wl-clipboard wlroots wofi xclip \
    xdg-desktop-portal-gnome xdg-desktop-portal-hyprland xdg-desktop-portal-lxqt \
    xdg-user-dirs-gtk xdotool xf86-video-vesa xorg-bdftopcf xorg-docs \
    xorg-font-util xorg-fonts-100dpi xorg-fonts-75dpi xorg-fonts-encodings \
    xorg-iceauth xorg-mkfontscale xorg-server xorg-server-common \
    xorg-server-devel xorg-server-xephyr xorg-server-xnest xorg-server-xvfb \
    xorg-sessreg xorg-setxkbmap xorg-smproxy xorg-x11perf xorg-xauth \
    xorg-xbacklight xorg-xcmsdb xorg-xcursorgen xorg-xdpyinfo xorg-xdriinfo \
    xorg-xev xorg-xgamma xorg-xhost xorg-xinput xorg-xkbcomp xorg-xkbevd \
    xorg-xkbutils xorg-xkill xorg-xlsatoms xorg-xlsclients xorg-xmodmap \
    xorg-xpr xorg-xprop xorg-xrandr xorg-xrdb xorg-xrefresh xorg-xset \
    xorg-xsetroot xorg-xvinfo xorg-xwayland xorg-xwd xorg-xwininfo xorg-xwud \
    yay yay-debug yelp zathura zathura-pdf-mupdf zig zsh

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
mkdir -p ~/job ~/Documents/books ~/Pictures/{walls,screenshots} ~/Videos/screencaptures ~/.local/bin

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
