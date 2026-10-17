#!/usr/bin/env bash
# Copies stdin to both Wayland CLIPBOARD and PRIMARY selection.
# A managed user (td via SUPER+SHIFT+T) has no compositor of its own: `usr term` starts its tmux session with
# WAYLAND_DISPLAY=/run/user/<owner uid>/wayland-N (an absolute socket path), and the owner's ACL lets that user write to
# the socket and nothing else of the owner's runtime directory (usr clipboard-acl).

content=$(cat; printf x)
content=${content%x}

[ -z "$content" ] && exit 0

# 1. an absolute WAYLAND_DISPLAY is used as it is; otherwise resolve the socket by its exact name in the runtime dir
case "${WAYLAND_DISPLAY:-}" in
    /*) ;;
    *)
        if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
            for candidate_dir in "${XDG_RUNTIME_DIR:-}" "/run/user/$(id -u)"; do
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
        ;;
esac

if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$content" | wl-copy
    printf '%s' "$content" | wl-copy -p
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$content" | xclip -in -selection clipboard
    printf '%s' "$content" | xclip -in -selection primary
fi
