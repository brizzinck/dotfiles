#!/usr/bin/env bash
# Grants td-user read/exec on our Wayland runtime dir so `su - td` sessions
# (Super+Shift+T) can reach wl-copy/wl-paste — /run/user/$UID is recreated
# each login so this must reapply on every Hyprland start.
setfacl -m u:td:rx "$XDG_RUNTIME_DIR"
setfacl -m u:td:rw "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
