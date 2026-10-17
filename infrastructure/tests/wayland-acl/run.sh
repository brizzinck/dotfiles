#!/usr/bin/env bash
# Offline test of wayland-acl.sh (the safety net behind wayland-acl.path): a fake runtime directory with real listening unix
# sockets served by a process named Hyprland (a symlink to python3), and a stub `usr` that records the environment it gets.
# The live session, its ACLs, and the user manager are never touched.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPT="$REPO/.config/hypr/scripts/wayland-acl.sh"
T=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
fails=0 passes=0
pass() { passes=$((passes + 1)); printf 'PASS  %s\n' "$1"; }
fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }

mkdir -p "$T/rt" "$T/bin"
ln -s "$(command -v python3)" "$T/bin/Hyprland"      # comm = Hyprland
ln -s "$(command -v python3)" "$T/bin/otherproc"
cat >"$T/usr" <<STUB
#!/usr/bin/env bash
echo "\$1 display=\${WAYLAND_DISPLAY:-} rt=\${XDG_RUNTIME_DIR:-}" >>"$T/calls"
STUB
chmod +x "$T/usr"
export XDG_RUNTIME_DIR="$T/rt" WAYLAND_ACL_USR="$T/usr" WAYLAND_ACL_WAIT=3

# listener BIN NAME [DELAY]: a process (named like BIN) that binds, waits DELAY seconds, then listens
listener() {
  "$T/bin/$1" -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); time.sleep(float(sys.argv[2])); s.listen(1); time.sleep(60)
' "$T/rt/$2" "${3:-0}" &
  PIDS+=($!)
  local i; for i in $(seq 40); do [ -S "$T/rt/$2" ] && return; sleep 0.05; done
}
wait_listen() { local i; for i in $(seq 40); do ss -xlnH 2>/dev/null | grep -q "$T/rt/$1" && return 0; sleep 0.05; done; return 1; }
calls() { wc -l <"$T/calls" 2>/dev/null || echo 0; }
: >"$T/calls"

# 1: no socket at all
"$SCRIPT"; expect "no socket: usr not run" test "$(calls)" = 0

# 2: a non-Hyprland listener is ignored (and the script does not wait for it forever)
listener otherproc wayland-7; wait_listen wayland-7
WAYLAND_ACL_WAIT=1 "$SCRIPT" 2>/dev/null; expect "a listener that is not Hyprland: usr not run" test "$(calls)" = 0

# 3: the compositor's socket
listener Hyprland wayland-3; wait_listen wayland-3
"$SCRIPT" >/dev/null
expect "compositor socket: usr clipboard-acl runs once" test "$(calls)" = 1
expect "it gets that display and the runtime dir" grep -qx "clipboard-acl display=wayland-3 rt=$T/rt" "$T/calls"
expect "a stamp is written (mode 700 dir)" bash -c '[ -s "$1/wayland-acl/stamp" ] && [ "$(stat -c %a "$1/wayland-acl")" = 700 ]' _ "$T/rt"

# 4: the same socket again costs nothing
"$SCRIPT" >/dev/null; "$SCRIPT" >/dev/null
expect "unchanged socket: no second run" test "$(calls)" = 1

# 5: a new compositor (new socket, new inode): runs again for the new name
kill "${PIDS[1]}"; sleep 0.2; rm -f "$T/rt/wayland-3"
listener Hyprland wayland-4; wait_listen wayland-4
"$SCRIPT" >/dev/null
expect "restarted compositor: runs again" test "$(calls)" = 2
expect "for the new display" grep -qx "clipboard-acl display=wayland-4 rt=$T/rt" "$T/calls"

# 6: two compositors (a nested test one): the oldest wins
sleep 1.2
listener Hyprland wayland-5; wait_listen wayland-5
rm -rf "$T/rt/wayland-acl"
"$SCRIPT" >/dev/null
expect "nested compositor: the oldest is taken" bash -c 'tail -1 "$1" | grep -q "display=wayland-4 "' _ "$T/calls"

# 7: bound but not listening yet (the path event comes with bind): the script waits for it
rm -rf "$T/rt/wayland-acl"; kill "${PIDS[@]:1}" 2>/dev/null; sleep 0.2; rm -f "$T/rt"/wayland-[0-9]; : >"$T/calls"
listener Hyprland wayland-6 1
"$SCRIPT" >/dev/null
expect "bound-but-not-listening socket: waited, then applied" grep -qx "clipboard-acl display=wayland-6 rt=$T/rt" "$T/calls"

# 8: the units
if command -v systemd-analyze >/dev/null; then
  v=$(systemd-analyze --user verify "$REPO/.config/systemd/user/wayland-acl.path" "$REPO/.config/systemd/user/wayland-acl.service" 2>&1 | grep -i 'wayland-acl' | grep -vi 'marked executable')
  expect "systemd-analyze verify: no complaint about the units" test -z "$v"
fi
expect "path unit watches the runtime dir with PathChanged and starts the service" bash -c 'grep -q "^PathChanged=%t$" "$1" && grep -q "^Unit=wayland-acl.service$" "$1"' _ "$REPO/.config/systemd/user/wayland-acl.path"
expect "service runs the script" grep -q '^ExecStart=%h/.config/hypr/scripts/wayland-acl.sh$' "$REPO/.config/systemd/user/wayland-acl.service"
expect "the Hyprland autostart still runs usr clipboard-acl" grep -q 'usr clipboard-acl' "$REPO/.config/hypr/hyprland.lua"

echo "wayland-acl: $passes passed, $fails failed"
[ "$fails" = 0 ]
