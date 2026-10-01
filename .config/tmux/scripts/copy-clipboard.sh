#!/usr/bin/env bash
# Copies stdin to both Wayland CLIPBOARD and PRIMARY selection.
# Ensures cross-user sessions (e.g. td via Super+Shift+T) find the Wayland socket.

content=$(cat; printf x)
content=${content%x}

[ -z "$content" ] && exit 0

# 1. Resolve Wayland socket and runtime dir
if [ -z "$XDG_RUNTIME_DIR" ] || [ -z "$WAYLAND_DISPLAY" ] || [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    for candidate_dir in "${XDG_RUNTIME_DIR:-}" "/run/user/1000" "/run/user/$(id -u)"; do
        [ -n "$candidate_dir" ] && [ -d "$candidate_dir" ] || continue
        for sock in "$candidate_dir"/wayland-*; do
            if [ -S "$sock" ]; then
                export XDG_RUNTIME_DIR="$candidate_dir"
                export WAYLAND_DISPLAY="$(basename "$sock")"
                break 2
            fi
        done
    done
fi

if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$content" | wl-copy 2>>/tmp/copy-clipboard.log
    printf '%s' "$content" | wl-copy -p 2>>/tmp/copy-clipboard.log
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$content" | xclip -in -selection clipboard 2>>/tmp/copy-clipboard.log
    printf '%s' "$content" | xclip -in -selection primary 2>>/tmp/copy-clipboard.log
fi
