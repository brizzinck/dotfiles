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

Palette: Everforest v2, variants black (default) and night, `themes/palette/palette.md`; switch with `theme black|night|toggle`. Launcher: rofi (`SUPER+space`); every other menu is the vim-key fzf modal (`fzf-menu`).
Keymap: `docs/keymap.md` (live: `SUPER+/`). More detail in `CLAUDE.md`.
