#!/usr/bin/env bash
# Copies stdin to both Wayland CLIPBOARD and PRIMARY selection.
# Ensures cross-user sessions (e.g. td via Super+Shift+T) find the Wayland socket.

content=$(cat; printf x)
content=${content%x}

[ -z "$content" ] && exit 0

# 1. Resolve Wayland socket and runtime dir (uses exact names to work with execute-only dirs)
if [ -z "$XDG_RUNTIME_DIR" ] || [ -z "$WAYLAND_DISPLAY" ] || [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    for candidate_dir in "${XDG_RUNTIME_DIR:-}" "/run/user/1000" "/run/user/$(id -u)"; do
        [ -n "$candidate_dir" ] && [ -d "$candidate_dir" ] || continue
        for candidate_name in "${WAYLAND_DISPLAY:-}" "wayland-1" "wayland-0" "wayland-2"; do
            [ -n "$candidate_name" ] || continue
            if [ -S "$candidate_dir/$candidate_name" ]; then
                export XDG_RUNTIME_DIR="$candidate_dir"
                export WAYLAND_DISPLAY="$candidate_name"
                break 2
            fi
        done
    done
fi

if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$content" | wl-copy
    printf '%s' "$content" | wl-copy -p
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$content" | xclip -in -selection clipboard
    printf '%s' "$content" | xclip -in -selection primary
fi
