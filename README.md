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
keymap md --write                  # regenerate docs/keymap.md from the live sources (doctor fails when it is stale)
```

Palette: Everforest v2, variants black (default) and night, `themes/palette/palette.md`; switch with `theme black|night|toggle`. Launcher: rofi (`SUPER+space`); every other menu is the vim-key fzf modal (`fzf-menu`).
Keymap: `docs/keymap.md` (generated; live search `SUPER+/`, reading page `SUPER+SHIFT+/`). More detail in `CLAUDE.md`.
