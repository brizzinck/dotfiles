# Installation

```sh
mkdir ~/dotfiles
git clone --recursive https://github.com/brizzinck/dotfiles.git ~/dotfiles
cd ~/dotfiles
git submodule update
```

```sh
chmod +x install.sh
./install.sh 
```

# Maintenance

```sh
sudo ./apply-system.sh --dry-run   # preview the root-level system layer (packages, /etc, timers, fstab, grub)
sudo ./apply-system.sh             # apply it (idempotent, --only <section> for one part)
./doctor.sh                        # PASS/FAIL health check of the approved state
docs/gen-keymap.sh                 # regenerate docs/keymap.md after changing Hyprland binds
```

Palette: Everforest Black, `themes/static/everforest-black/palette.md`. Launcher: rofi (`SUPER+space`).
Keymap: `docs/keymap.md` (live: `SUPER+/`). More detail in `CLAUDE.md`.
