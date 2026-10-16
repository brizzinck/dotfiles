#!/usr/bin/env bash
# Qt (qt6ct): colors/everforest.conf follows the `current` link. qt6ct watches qt6ct.conf, so touching it lets running
# Qt apps re-read the palette (best effort; apps that do not watch pick it up at their next start). No content changes.
set -u
cfg=${XDG_CONFIG_HOME:-$HOME/.config}/qt6ct/qt6ct.conf
[[ -e $cfg ]] || exit 0
touch "$cfg" && echo "qt6ct: config touched"
