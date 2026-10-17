#!/usr/bin/env bash
# wayland-acl.sh - put the managed users' ACL (usr clipboard-acl) on the session compositor's CURRENT wayland-N socket.
#
# Why: a new compositor (crash restart, login) creates a new socket that inherits the default ACL of the runtime directory
# (`u:tgconfirm:---`), so the tgconfirm confirmation popup (and td's clipboard) cannot connect until `usr clipboard-acl` ran
# again. The Hyprland autostart runs it once per compositor instance; this script is the safety net that user unit
# wayland-acl.path starts whenever an entry appears in or leaves $XDG_RUNTIME_DIR (systemd PathChanged, inotify on the directory).
#
# The user manager has no WAYLAND_DISPLAY, so the socket is found like the broker finds it, minus the logind part: a listening
# $XDG_RUNTIME_DIR/wayland-[0-9] whose server is a process named Hyprland of this uid (`ss -xlp`); with several (a nested test
# compositor) the OLDEST one is taken. The broker still verifies the compositor itself, so a wrong guess here only means a refused
# popup (doctor mcp-send-wayland / mcp-send-route say so), never a send. Nothing happens when no such socket exists.
# A stamp (display, inode, process start) in $XDG_RUNTIME_DIR/wayland-acl/ makes repeated triggers free.
# Env (tests): XDG_RUNTIME_DIR, WAYLAND_ACL_USR (the usr command), WAYLAND_ACL_COMM (process name, default Hyprland),
# WAYLAND_ACL_WAIT (seconds to wait for a socket that is bound but not yet listening, default 5).
set -u
rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
usr="${WAYLAND_ACL_USR:-$HOME/.local/bin/usr}"
comm="${WAYLAND_ACL_COMM:-Hyprland}"
wait_s="${WAYLAND_ACL_WAIT:-5}"
dry=0
[ "${1:-}" = --dry-run ] && dry=1
stamp_dir="$rt/wayland-acl"
me=$(id -u)

# prints "display inode start" of the session compositor's socket, or nothing
pick() {
  local best="" best_start=0 sock pid start line
  while IFS= read -r line; do
    sock=$(awk '{print $5}' <<<"$line")
    case "$sock" in "$rt"/wayland-[0-9]) ;; *) continue ;; esac
    pid=$(grep -o 'pid=[0-9]*' <<<"$line" | head -1 | cut -d= -f2)
    [ -n "$pid" ] && [ -r "/proc/$pid/comm" ] || continue
    [ "$(<"/proc/$pid/comm")" = "$comm" ] || continue
    [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = "$me" ] || continue
    start=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    [ -n "$start" ] || continue
    if [ -z "$best" ] || [ "$start" -lt "$best_start" ]; then
      best="$(basename "$sock") $(stat -c %i "$sock") $start"
      best_start=$start
    fi
  done < <(ss -xlpnH 2>/dev/null)
  [ -n "$best" ] && printf '%s\n' "$best"
}

have_socket_files() { compgen -G "$rt/wayland-[0-9]" >/dev/null; }

cur=""
for ((i = 0; i <= wait_s * 4; i++)); do
  cur=$(pick)
  [ -n "$cur" ] && break
  # a socket that is bound but not listening yet (the event comes with bind): wait; no socket file at all: nothing to do
  have_socket_files || exit 0
  [ "$i" -lt $((wait_s * 4)) ] && sleep 0.25
done
[ -n "$cur" ] || { echo "wayland-acl: wayland socket(s) present, but no listening $comm of uid $me" >&2; exit 0; }

if [ "$dry" = 1 ]; then echo "$cur"; exit 0; fi
old=$(cat "$stamp_dir/stamp" 2>/dev/null || true)
[ "$cur" = "$old" ] && exit 0

# run, then look again: a socket that appeared while we ran produced no new trigger (systemd ignores events of a running service)
for _ in 1 2 3; do
  WAYLAND_DISPLAY="${cur%% *}" XDG_RUNTIME_DIR="$rt" "$usr" clipboard-acl || echo "wayland-acl: usr clipboard-acl failed" >&2
  again=$(pick)
  [ "$again" = "$cur" ] && break
  cur="$again"
  [ -n "$cur" ] || exit 0
done
mkdir -p "$stamp_dir" && chmod 700 "$stamp_dir" && printf '%s\n' "$cur" >"$stamp_dir/stamp"
echo "wayland-acl: ACL applied for ${cur%% *}"
