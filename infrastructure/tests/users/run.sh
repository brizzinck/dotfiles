#!/usr/bin/env bash
# Offline tests of the managed-user stage (U7): registry parser, rendered sudoers/polkit, the usr helper in scratch directories
# (sync, profile links, clipboard ACL), vault-who's machinectl rule and nvim's shared-root choice. No sudo, no real user is
# touched (the scratch tree lives in $TMPDIR). Run: infrastructure/tests/users/run.sh [--quick]   (doctor runs --quick)
#   --quick   skips the nvim cases
set -u
export PYTHONDONTWRITEBYTECODE=1   # python3 -I ignores PYTHON* variables (hence -B there); this covers the other interpreters: no __pycache__ in the repo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
USR="$REPO/.local/bin/usr"
QUICK=0
[ "${1:-}" = --quick ] && QUICK=1
T="$(mktemp -d)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { # expect NAME WANT GOT
  if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi
}
ME="$(command id -un)"

# ── registry parser with a fixture that has a service user ─────────────────────
cat >"$T/m.tsv" <<TSV
# fixture
td	cli	interactive,clipboard	orange	agents
yc	cli	interactive	blue
aimcp	-	service,noacl,nobecome,create	purple	Telegram MCP
tgconfirm	-	service,noacl,nobecome,create,wayland	aqua	Telegram send confirmation
TSV
export USR_MANAGED_TSV="$T/m.tsv"
# shellcheck source=../../users/lib.sh
source "$REPO/infrastructure/users/lib.sh"
expect "managed_users" "td yc aimcp tgconfirm" "$(managed_users | paste -sd' ' -)"
expect "interactive" "td yc" "$(managed_users interactive | paste -sd' ' -)"
expect "become" "td yc" "$(managed_users become | paste -sd' ' -)"
expect "acl" "td yc" "$(managed_users acl | paste -sd' ' -)"
expect "profile" "td yc" "$(managed_users profile | paste -sd' ' -)"
expect "clipboard" "td" "$(managed_users clipboard | paste -sd' ' -)"
expect "create" "aimcp tgconfirm" "$(managed_users create | paste -sd' ' -)"
expect "service" "aimcp tgconfirm" "$(managed_users service | paste -sd' ' -)"
expect "wayland (a clipboard user reaches the socket too)" "td tgconfirm" "$(managed_users wayland | paste -sd' ' -)"
expect "accent" "purple" "$(managed_field aimcp accent)"
expect "valid fixture" "" "$(managed_validate "$ME")"
printf 'root\t-\t-\tred\n%s\t-\t-\tred\nx\tcli\tservice\tred\ny\t-\tbogus\tred\nz\tnoprofile\t-\tred\n' "$ME" >"$T/bad.tsv"
bad_out="$(USR_MANAGED_TSV="$T/bad.tsv" managed_validate "$ME")"
for needle in "root must never be managed" "must not be listed as managed" "service user cannot have" "unknown flag bogus" "profile noprofile"; do
  case "$bad_out" in *"$needle"*) ok ;; *) bad "validate did not report: $needle" ;; esac
done
# the real registry is valid and never lists root or the owner
unset USR_MANAGED_TSV
expect "real registry valid" "" "$(managed_validate "$ME")"
export USR_MANAGED_TSV="$T/m.tsv"

# ── apply-system.sh --only users (dry run, fixture): rendered sudoers + polkit, service user creation ────────────────
# The accounts td, yc and aimcp may or may not exist on the machine that runs this test (aimcp does since M1), so a fake
# `getent` shadows the real one: passwd answers only for the owner and root (fixture passwd), everything else is real.
mkdir -p "$T/fakebin"
cat >"$T/fakebin/getent" <<'FAKE'
#!/bin/sh
if [ "${1:-}" = passwd ] && [ -n "${2:-}" ]; then
  case "$2" in "$FAKE_PASSWD_OWNER" | root) exec /usr/bin/getent "$@" ;; *) exit 2 ;; esac
fi
exec /usr/bin/getent "$@"
FAKE
chmod +x "$T/fakebin/getent"
mkdir -p "$T/dryhome/skel"
setfacl -d -m g::r-x,o::r-x,m::r-x "$T/dryhome/skel" 2>/dev/null
printf 'echo hi\n' >"$T/dryhome/leak.sh"
dry="$(PATH="$T/fakebin:$PATH" FAKE_PASSWD_OWNER="$ME" USERS_ACL_ROOT="$T/dryhome" "$REPO/apply-system.sh" --dry-run --only users 2>&1)"
case "$dry" in *"Runas_Alias USR_MANAGED = td, yc"*) ok ;; *) bad "sudoers Runas list is not td, yc" ;; esac
case "$dry" in *"var managed = [\"td\", \"yc\"];"*) ok ;; *) bad "polkit list is not td, yc" ;; esac
sudoers_rules="$(printf '%s\n' "$dry" | sed -n '/rendered .*50-usr-managed (mode/,/install -Dm440/p' | grep -E '\| (Runas_Alias|[a-z]+ ALL =)')"
case "$sudoers_rules" in *aimcp* | *root*) bad "sudoers rules name aimcp or root (nobecome / never root)" ;; *) ok ;; esac
polkit_rules="$(printf '%s\n' "$dry" | grep 'var managed =')"
case "$polkit_rules" in *aimcp* | *root*) bad "polkit list names aimcp or root" ;; *) ok ;; esac
case "$dry" in *"useradd -m -U -s /usr/bin/nologin -K HOME_MODE=0700 aimcp"*) ok ;; *) bad "dry run does not create the service user aimcp" ;; esac
case "$dry" in *"passwd -l aimcp"*) ok ;; *) bad "dry run does not lock aimcp's password" ;; esac
if printf '%s\n' "$dry" | grep -E '^\[dry-run\] useradd .* (td|yc)$' >/dev/null; then bad "dry run would create td or yc"; else ok; fi
# render the real templates for the owner and check them with the real parsers
sed -e "s|@OWNER@|$ME|g" -e 's|@MANAGED@|td, yc|' "$REPO/infrastructure/users/sudoers/50-usr-managed.in" >"$T/sudoers"
if visudo -c -f "$T/sudoers" >/dev/null 2>&1; then ok; else bad "visudo rejects the rendered sudoers drop-in"; fi
sed -e "s|@OWNER@|$ME|g" -e 's|@MANAGED_JS@|"td", "yc"|' "$REPO/infrastructure/users/polkit/50-usr-managed.rules.in" >"$T/rules.js"
if command -v node >/dev/null 2>&1; then
  if node --check "$T/rules.js" 2>/dev/null; then ok; else bad "node --check rejects the rendered polkit rule"; fi
  if out="$(node "$HERE/polkit-rule-test.js" "$T/rules.js" "$ME" 2>&1)"; then ok; else bad "polkit rule logic: $out"; fi
fi

# ── vault-who: a window of `usr term` is the managed user ───────────────────────
out="$(python3 -I -B - "$REPO/.config/hypr/scripts/vault-who.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vw", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases = [
    (["machinectl", "--quiet", "shell", "-E", "TERM=xterm", "-E", "WAYLAND_DISPLAY=/run/user/1000/wayland-1", "td@", "/usr/bin/zsh", "-lc", "x"], "td"),
    (["machinectl", "shell", "--uid=yc"], "yc"),
    (["machinectl", "shell"], "root"),
    (["machinectl", "list"], None),
]
print("\n".join(f"{m.machinectl_target(a)!s}|{w!s}" for a, w in cases))
PY
)"
expect "vault-who machinectl rule" "td|td
yc|yc
root|root
None|None" "$out"

# ── usr: scratch publish, profile links, clipboard ACL ──────────────────────────
export USR_SRV_DOTFILES="$T/srv"
mkdir -p "$T/srv" "$T/home"
export HOME="$T/home"
export XDG_STATE_HOME="$T/home/.local/state"
"$USR" sync --worktree --quiet >/dev/null 2>&1 || bad "usr sync --worktree failed"
[ -f "$T/srv/.zshrc" ] && ok || bad "sync: .zshrc not published"
[ -e "$T/srv/private" ] && bad "sync: private/ was published" || ok
[ -e "$T/srv/env.secret.sh" ] && bad "sync: env.secret.sh was published" || ok
[ -x "$T/srv/.local/bin/usr" ] && ok || bad "sync: usr itself is not published"
[ -f "$T/srv/.published" ] && ok || bad "sync: .published missing"
mkdir -p "$T/h/td/.config"
ln -s ../dotfiles/.config/tmux "$T/h/td/.config/tmux"
echo old >"$T/h/td/.gitconfig"
run_link() { USR_TARGET_USER=td USR_TARGET_HOME="$T/h/td" "$USR" _link "$@" 2>&1; }
dry_out="$(run_link --dry-run)"
case "$dry_out" in *"move   ~/.config/tmux (link -> ../dotfiles/.config/tmux)"*"link   ~/.config/tmux -> $T/srv/.config/tmux"*) ok ;; *) bad "link --dry-run does not list the tmux move + link" ;; esac
[ -L "$T/h/td/.zshrc" ] && bad "link --dry-run wrote a link" || ok
run_link >/dev/null
expect ".zshrc link" "$T/srv/.zshrc" "$(readlink "$T/h/td/.zshrc")"
expect "tmux link replaced" "$T/srv/.config/tmux" "$(readlink "$T/h/td/.config/tmux")"
expect "old gitconfig backed up" "old" "$(cat "$T"/h/td/.local/state/usr/backup-*/.gitconfig 2>/dev/null)"
case "$(cat "$T/h/td/.zshrc.local" 2>/dev/null)" in *'PROMPT="%F{#ea9e77}td%f ${PROMPT}"'*) ok ;; *) bad "zshrc.local accent block missing" ;; esac
case "$(cat "$T/h/td/.tmux.local.conf" 2>/dev/null)" in *'#ea9e77'*) ok ;; *) bad "tmux.local.conf accent block missing" ;; esac
case "$(run_link)" in *"0 linked, 17 already linked"*) ok ;; *) bad "second link run is not a no-op" ;; esac
# DEV-b: envs, fzf-menu, bw-setup and the mise config are in the cli profile; envs finds vault-bw.py inside the published tree
for want in .config/mise .local/bin/envs .local/bin/fzf-menu .local/bin/bw-setup; do
  grep -qx "$want" "$REPO/infrastructure/users/profiles/cli.txt" && ok || bad "cli profile does not list $want"
  [ -e "$T/srv/$want" ] && ok || bad "sync: $want is not published"
done
[ -L "$T/h/td/.local/bin/envs" ] && [ "$(readlink "$T/h/td/.local/bin/envs")" = "$T/srv/.local/bin/envs" ] && ok || bad "td's envs is not linked to the published copy"
out="$(python3 -I -B - "$T/srv/.local/bin/envs" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("envs_mod", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("envs_mod", loader))
loader.exec_module(m)
print(m.REPO, m.VAULT_BW.exists())
PY
)"
expect "envs resolves its repo and vault-bw.py inside the published tree" "$T/srv True" "$out"
# bw-setup without a Wayland socket asks pinentry in the terminal (pinentry-curses), with one it keeps the themed pinentry
mkdir -p "$T/fakebin"
printf '#!/bin/sh\nexit 0\n' >"$T/fakebin/pinentry-curses"
printf '#!/bin/sh\nexit 0\n' >"$T/fakebin/pinentry-themed"
cat >"$T/fakebin/rbw" <<'RBW'
#!/bin/sh
[ "$1" = config ] && [ "$2" = set ] && [ "$3" = pinentry ] && echo "$4" >>"$FAKE_PIN_LOG"
[ "$1" = config ] && [ "$2" = set ] && [ "$3" = lock_timeout ] && echo "$4" >>"$FAKE_PIN_LOG.lock"
[ "$1" = login ] && exit 1
exit 0
RBW
chmod +x "$T/fakebin"/*
: >"$T/pin.log"
(FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY="" XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "bw-setup without a Wayland display uses pinentry-curses" "$T/fakebin/pinentry-curses" "$(tail -1 "$T/pin.log")"
mkdir -p "$T/run"; : >"$T/run/wayland-fake"
(FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY=wayland-fake XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "bw-setup with a writable Wayland socket keeps pinentry-themed" "$T/fakebin/pinentry-themed" "$(tail -1 "$T/pin.log")"
(FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY=wayland-nosuch XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "bw-setup with a Wayland socket that is not writable falls back to the terminal" "$T/fakebin/pinentry-curses" "$(tail -1 "$T/pin.log")"
# FIX-DEVb: the owner keeps the one-year lock timeout, a managed user (the checkout belongs to someone else) gets one hour
: >"$T/pin.log.lock"
(FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY="" XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "bw-setup for the owner: lock_timeout one year" "31536000" "$(tail -1 "$T/pin.log.lock")"
(BW_SETUP_FAKE_OWNER=someone-else FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY="" XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "bw-setup for a managed user: lock_timeout one hour" "3600" "$(tail -1 "$T/pin.log.lock")"
run_link --restore >/dev/null
expect "restore gitconfig" "old" "$(cat "$T/h/td/.gitconfig" 2>/dev/null)"
expect "restore tmux link" "../dotfiles/.config/tmux" "$(readlink "$T/h/td/.config/tmux")"
[ -L "$T/h/td/.zshrc" ] && bad "restore left the new .zshrc link" || ok
# a service user gets no profile and no terminal
printf 'svc\t-\tservice,noacl,nobecome\tred\n' >"$T/svc.tsv"
if USR_MANAGED_TSV="$T/svc.tsv" USR_TARGET_USER=svc USR_TARGET_HOME="$T/h/svc" "$USR" _link 2>&1 | grep -q 'nothing to link'; then ok; else bad "service user: _link did not say nothing to link"; fi
if USR_MANAGED_TSV="$T/svc.tsv" "$USR" term svc --dry-run >/dev/null 2>&1; then bad "usr term works for a service user"; else ok; fi
case "$("$USR" term td --dry-run 2>&1)" in *"_session td tmux"*) ok ;; *) bad "usr term td --dry-run prints no session command" ;; esac

# clipboard ACL on a fake runtime dir (sockets): the clipboard user gets x on the dir, rw on the Wayland socket, deny on the rest
printf 'nobody\t-\tinteractive,clipboard\torange\n' >"$T/clip.tsv"
mkdir -p "$T/rt"
chmod 700 "$T/rt"
(cd "$T/rt" && python3 -I -B -c '
import socket, os
for n in ("wayland-9", "pipewire-0", "bus"):
    s = socket.socket(socket.AF_UNIX); s.bind(n); os.chmod(n, 0o666)
os.makedirs("systemd", mode=0o755); os.makedirs("hub", mode=0o755)
s = socket.socket(socket.AF_UNIX); s.bind("systemd/io.systemd.Manager"); os.chmod("systemd/io.systemd.Manager", 0o666)
open("hub/state.json", "w").write("{}"); os.chmod("hub/state.json", 0o644)
')
export XDG_RUNTIME_DIR="$T/rt" WAYLAND_DISPLAY=wayland-9
USR_MANAGED_TSV="$T/clip.tsv" "$USR" clipboard-acl >/dev/null 2>&1
expect "clipboard dir" "user:nobody:--x" "$(getfacl -p "$T/rt" 2>/dev/null | grep '^user:nobody:')"
expect "clipboard wayland" "user:nobody:rw-" "$(getfacl -p "$T/rt/wayland-9" 2>/dev/null | grep '^user:nobody:')"
expect "clipboard pipewire denied" "user:nobody:---" "$(getfacl -p "$T/rt/pipewire-0" 2>/dev/null | grep '^user:nobody:')"
expect "clipboard bus denied" "user:nobody:---" "$(getfacl -p "$T/rt/bus" 2>/dev/null | grep '^user:nobody:')"
expect "clipboard socket in a subdirectory denied" "user:nobody:---" "$(getfacl -p "$T/rt/systemd/io.systemd.Manager" 2>/dev/null | grep '^user:nobody:')"
(cd "$T/rt" && python3 -I -B -c '
import socket, os
os.makedirs("later", mode=0o755)
s = socket.socket(socket.AF_UNIX); s.bind("later-sock"); os.chmod("later-sock", 0o666)
open("later-file", "w").write("x"); os.chmod("later-file", 0o644)
')
expect "clipboard: a directory created later inherits the deny (default ACL)" "user:nobody:---" "$(getfacl -p "$T/rt/later" 2>/dev/null | grep '^user:nobody:')"
expect "clipboard: a socket created later inherits the deny" "user:nobody:---" "$(getfacl -p "$T/rt/later-sock" 2>/dev/null | grep '^user:nobody:')"
expect "clipboard: the modes creators ask for are unchanged by the default ACL (dir 755, socket 666 after chmod, file 644)" "755 666 644" "$(stat -c %a "$T/rt/later" "$T/rt/later-sock" "$T/rt/later-file" | paste -sd' ')"
expect "clipboard first-level subdirectory denied (no traversal)" "user:nobody:---" "$(getfacl -p "$T/rt/hub" 2>/dev/null | grep '^user:nobody:')"
# a wayland-only user (the tgconfirm popup) gets exactly the same ACL
printf 'nobody\t-\tservice,noacl,wayland\taqua\n' >"$T/wl.tsv"
setfacl -bk "$T/rt" "$T/rt/wayland-9" "$T/rt/pipewire-0" "$T/rt/bus" 2>/dev/null
USR_MANAGED_TSV="$T/wl.tsv" "$USR" clipboard-acl >/dev/null 2>&1
expect "wayland dir" "user:nobody:--x" "$(getfacl -p "$T/rt" 2>/dev/null | grep '^user:nobody:')"
expect "wayland socket" "user:nobody:rw-" "$(getfacl -p "$T/rt/wayland-9" 2>/dev/null | grep '^user:nobody:')"
expect "wayland pipewire denied" "user:nobody:---" "$(getfacl -p "$T/rt/pipewire-0" 2>/dev/null | grep '^user:nobody:')"
# acl-reach.py (doctor mcp-send-route): follows the OTHER bits, not only named ACL entries
REACH="$REPO/infrastructure/users/acl-reach.py"
NOBODY=$(id -u nobody 2>/dev/null || echo 65534)
mkdir -p "$T/rt2/pub" && chmod 700 "$T/rt2" && chmod 755 "$T/rt2/pub"
(cd "$T/rt2" && python3 -I -B -c '
import socket, os
for n in ("wayland-9", "bus", "pub/inner.sock"):
    s = socket.socket(socket.AF_UNIX); s.bind(n); os.chmod(n, 0o666)
open("pub/readable.txt", "w").write("x"); os.chmod("pub/readable.txt", 0o644)
open("private.txt", "w").write("x"); os.chmod("private.txt", 0o600)
')
setfacl -m "u:nobody:--x" "$T/rt2"
reach="$("$REACH" "$NOBODY" "$T/rt2" --allow wayland-9)"
case "$reach" in *"$T/rt2/bus"*"readable.txt"* | *"readable.txt"*"$T/rt2/bus"*) ok ;; *) bad "acl-reach finds the 0666 socket and the 0644 file that only the other bits expose: $reach" ;; esac
case "$reach" in *"inner.sock"*) ok ;; *) bad "acl-reach finds a 0666 socket in a 0755 subdirectory" ;; esac
case "$reach" in *private.txt* | *wayland-9*) bad "acl-reach reported a 0600 file or the allowed Wayland socket: $reach" ;; *) ok ;; esac
export XDG_RUNTIME_DIR="$T/rt2" WAYLAND_DISPLAY=wayland-9
printf 'nobody\t-\tservice,noacl,wayland\taqua\n' >"$T/wl2.tsv"
USR_MANAGED_TSV="$T/wl2.tsv" "$USR" clipboard-acl >/dev/null 2>&1
reach="$("$REACH" "$NOBODY" "$T/rt2" --allow wayland-9)"
expect "acl-reach after usr clipboard-acl: nothing but the Wayland socket is reachable" "" "$reach"
unset XDG_RUNTIME_DIR WAYLAND_DISPLAY

# ── the picker and the session command, with stub fzf-menu / ghostty / machinectl / sudo / su ───────────────────
mkdir -p "$T/bin"
cat >"$T/bin/fzf-menu" <<'STUB'
#!/usr/bin/env bash
# stub: choose the first row; STUB_KEY is the key line (empty = Enter)
rows=$(cat); who=$(printf '%s\n' "$rows" | head -1 | cut -f1)
printf '%s\n%s\n' "${STUB_KEY:-}" "$who"
STUB
cat >"$T/bin/ghostty" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
STUB
cat >"$T/bin/machinectl" <<'STUB'
#!/usr/bin/env bash
printf 'machinectl %s\n' "$*" >>"$STUB_LOG"
[ "${STUB_MACHINECTL_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
cat >"$T/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUB_LOG"
[ "${STUB_SUDO_FAIL:-0}" = 1 ] && exit 1
exit 0
STUB
cat >"$T/bin/su" <<'STUB'
#!/usr/bin/env bash
printf 'su %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB
chmod +x "$T/bin/"*
export STUB_LOG="$T/stub.log"
printf 'nobody\t-\tinteractive,clipboard\torange\n' >"$T/pick.tsv"
for case in ":_session nobody tmux" "alt-enter:_session nobody shell" "attach:_session nobody attach"; do
  : >"$STUB_LOG"
  PATH="$T/bin:$PATH" STUB_KEY="${case%%:*}" USR_MANAGED_TSV="$T/pick.tsv" "$USR" menu >/dev/null 2>&1
  sleep 0.2
  case "$(cat "$STUB_LOG")" in *"--title=nobody -e $USR ${case#*:}"*) ok ;; *) bad "usr menu key [${case%%:*}] did not open: ${case#*:} (log: $(cat "$STUB_LOG"))" ;; esac
done
# usr exec: sudo -n -u USER -i, with -C a cd wrapper; a service user is still reachable (it asks for the sudo password itself)
: >"$STUB_LOG"
PATH="$T/bin:$PATH" USR_MANAGED_TSV="$T/pick.tsv" "$USR" exec nobody -- ls -la /x >/dev/null 2>&1
expect "usr exec" "sudo -n -u nobody -i -- ls -la /x" "$(cat "$STUB_LOG")"
: >"$STUB_LOG"
PATH="$T/bin:$PATH" USR_MANAGED_TSV="$T/pick.tsv" "$USR" exec nobody -C /srv/x -- make test >/dev/null 2>&1
case "$(cat "$STUB_LOG")" in "sudo -n -u nobody -i -- sh -c "*"_ /srv/x make test") ok ;; *) bad "usr exec -C: $(cat "$STUB_LOG")" ;; esac
if PATH="$T/bin:$PATH" USR_MANAGED_TSV="$T/pick.tsv" "$USR" exec stranger -- id >/dev/null 2>&1; then bad "usr exec works for an unmanaged user"; else ok; fi
export XDG_RUNTIME_DIR="$T/rt" WAYLAND_DISPLAY=wayland-9
: >"$STUB_LOG"
PATH="$T/bin:$PATH" USR_MANAGED_TSV="$T/pick.tsv" "$USR" _session nobody tmux >/dev/null 2>&1
log="$(cat "$STUB_LOG")"
case "$log" in *"machinectl --quiet shell -E TERM="*"-E WAYLAND_DISPLAY=$T/rt/wayland-9 nobody@ "*"-lc exec tmux new-session -s term-"*"-e WAYLAND_DISPLAY=$T/rt/wayland-9 \\; set-option destroy-unattached on"*) ok ;; *) bad "machinectl session line: $log" ;; esac
: >"$STUB_LOG"
PATH="$T/bin:$PATH" STUB_MACHINECTL_FAIL=1 USR_MANAGED_TSV="$T/pick.tsv" "$USR" _session nobody shell >/dev/null 2>&1
case "$(cat "$STUB_LOG")" in *"machinectl "*"sudo -n -u nobody -H env "*) ok ;; *) bad "no sudo fallback when machinectl fails at once: $(cat "$STUB_LOG")" ;; esac
: >"$STUB_LOG"
PATH="$T/bin:$PATH" STUB_MACHINECTL_FAIL=1 STUB_SUDO_FAIL=1 USR_MANAGED_TSV="$T/pick.tsv" "$USR" _session nobody shell >/dev/null 2>&1
case "$(cat "$STUB_LOG")" in *"su - nobody -c "*) ok ;; *) bad "no su fallback when sudo fails too: $(cat "$STUB_LOG")" ;; esac
unset XDG_RUNTIME_DIR WAYLAND_DISPLAY

# ── nvim: which plugin/Mason root is chosen ─────────────────────────────────────
if [ "$QUICK" = 0 ] && command -v nvim >/dev/null 2>&1; then
  mkdir -p "$T/shared/lazy"
  : >"$T/shared/.ready"
  probe() { env "$@" XDG_DATA_HOME="$T/d" XDG_STATE_HOME="$T/s" XDG_CACHE_HOME="$T/c" timeout 30 nvim --headless -u NONE --cmd "set rtp+=$REPO/.config/nvim" \
    -c 'lua io.stdout:write(tostring(require("shared").root) .. "\n")' -c 'qa!' 2>&1 </dev/null | tail -1; }
  chmod a-w "$T/shared"
  expect "nvim: ready + read-only = shared" "$T/shared" "$(probe NVIM_SHARED_DEFAULT="$T/shared")"
  chmod u+w "$T/shared"
  expect "nvim: writable (owner) = own dirs" "nil" "$(probe NVIM_SHARED_DEFAULT="$T/shared")"
  chmod a-w "$T/shared"
  expect "nvim: NVIM_SHARED=0" "nil" "$(probe NVIM_SHARED_DEFAULT="$T/shared" NVIM_SHARED=0)"
  expect "nvim: NVIM_SHARED forced" "/x/y" "$(probe NVIM_SHARED=/x/y)"
  rm -f "$T/shared/.ready" 2>/dev/null
  chmod u+w "$T/shared"
  rm -f "$T/shared/.ready"
  chmod a-w "$T/shared"
  expect "nvim: no .ready = own dirs" "nil" "$(probe NVIM_SHARED_DEFAULT="$T/shared")"
fi

# ── home ACL cleanup: skeletons stripped, secrets owner-only, keep list, idempotent, before-state (home-acl.sh) ─────────
HA="$REPO/infrastructure/users/home-acl.sh"
if mkdir -p "$T/aclprobe" && setfacl -d -m g::r-x "$T/aclprobe" 2>/dev/null && getfacl -p "$T/aclprobe" 2>/dev/null | grep -q '^default:'; then
  # the dry run of apply-system.sh reported the fixture home and changed nothing
  case "$dry" in *"extended ACLs under $T/dryhome: "*) ok ;; *) bad "dry run: no home ACL report for the fixture home" ;; esac
  case "$dry" in *"would strip 1 unintended ACLs and tighten "*) ok ;; *) bad "dry run: wrong strip/tighten summary ($(printf '%s\n' "$dry" | grep 'would strip' | head -1))" ;; esac
  getfacl -p "$T/dryhome/skel" | grep -q '^default:' && ok || bad "dry run removed the fixture's default ACL"

  H="$T/aclhome" ST="$T/aclstate" REPOFIX="$T/aclrepo"
  mkdir -p "$H/skel/sub" "$H/keep/in" "$H/sec/dir" "$H/sec2" "$H/outside" "$ST" "$REPOFIX"
  setfacl -d -m g::r-x,o::r-x,m::r-x "$H/skel" "$H/keep"
  mkdir -p "$H/skel/sub2" && touch "$H/skel/f" "$H/keep/in/f"            # inherit the skeleton
  touch "$H/resid" "$H/mgd" "$H/oth" "$H/geff"
  setfacl -m u:nobody:r "$H/resid" && setfacl -x u:nobody "$H/resid"       # what `setfacl -x user:td` leaves: a mask
  setfacl -m u:nobody:r "$H/mgd"                                          # a managed user's entry (nobody stands for td)
  setfacl -m u:daemon:r "$H/oth"                                          # somebody else's entry: kept
  chmod 640 "$H/geff" && setfacl -n -m m::rwx "$H/geff"                   # group entry r--, mask rwx: effective r--
  printf 'x\n' >"$H/outside/f"; chmod 644 "$H/outside/f"
  printf 'k\n' >"$H/sec/f644"; chmod 644 "$H/sec/f644"
  printf '#!/bin/sh\n' >"$H/sec/dir/run"; chmod 755 "$H/sec/dir/run"; chmod 755 "$H/sec/dir"; chmod 755 "$H/sec"
  printf 's\n' >"$H/sec2/file"; chmod 644 "$H/sec2/file"; chmod 755 "$H/sec2"
  ln -s "$H/outside" "$H/sec/link"
  printf 'e\n' >"$REPOFIX/env.secret.sh"; chmod 755 "$REPOFIX/env.secret.sh"
  printf 'keep\n' >"$T/keep.txt"
  printf 'sec full\nsec2 top   # an app writes here\nmissing top\n@REPO@/env.secret.sh\n' >"$T/secrets.txt"
  ha() { "$HA" "$1" --root "$H" --owner "$ME" --state "$ST" --managed nobody --keep "$T/keep.txt" --secrets "$T/secrets.txt" --repo "$REPOFIX" "${@:2}" 2>&1; }
  acl_files() { getfacl -R -p -s "$H" 2>/dev/null | sed -n 's/^# file: //p' | sort; }
  acl_before="$(acl_files)"
  modes_before="$(find "$H" -xdev ! -type l -printf '%m %p\n' | sort)"

  chk="$(ha check)"
  case "$chk" in *"marker=0"*) ok ;; *) bad "home-acl check: marker should be absent before apply" ;; esac
  case "$chk" in *"acl_count=0"*) bad "home-acl check sees no unintended ACL in the fixture" ;; *) ok ;; esac
  case "$chk" in *"mode_count=0"*) bad "home-acl check sees no wide secret in the fixture" ;; *) ok ;; esac

  rep="$(ha report)"
  expect "report: nothing changed (ACLs)" "$acl_before" "$(acl_files)"
  expect "report: nothing changed (modes)" "$modes_before" "$(find "$H" -xdev ! -type l -printf '%m %p\n' | sort)"
  case "$rep" in *"extended ACLs under $H: "*"unintended, to strip"*) ok ;; *) bad "report: no ACL summary" ;; esac
  case "$rep" in *"def:user+def:group+def:mask+def:other"*) ok ;; *) bad "report: the skeleton kind is not listed" ;; esac
  case "$rep" in *"KEPT, a named entry of somebody else (1)"*"$H/oth"*) ok ;; *) bad "report: the named entry of daemon is not listed as kept" ;; esac
  case "$rep" in *"KEPT, listed in keep.txt"*) ok ;; *) bad "report: the keep list is not applied" ;; esac
  for needle in "755 -> 700  ~/sec/dir" "755 -> 700  ~/sec/dir/run" "644 -> 600  ~/sec/f644" "755 -> 700  ~/sec2"; do
    case "$rep" in *"$needle"*) ok ;; *) bad "report: not listed with its before -> after mode: $needle" ;; esac
  done
  case "$rep" in *"$REPOFIX/env.secret.sh"*"755 -> 700"*) ok ;; *) bad "report: @REPO@/env.secret.sh is not listed" ;; esac
  case "$rep" in *"absent (nothing to do): ~/missing"*) ok ;; *) bad "report: an absent secret path is not mentioned" ;; esac
  case "$rep" in *"$H/outside/f"*) bad "report lists a path outside the secret locations" ;; *) ok ;; esac

  app="$(ha apply)"
  case "$app" in *"before-state"*"home-acl-before-"*) ok ;; *) bad "apply: no before-state announced" ;; esac
  # what is left: only the daemon entry and the kept tree
  left="$(acl_files | grep -v -e "^$H/oth\$" -e "^$H/keep" || true)"
  expect "apply: no unintended ACL left" "" "$left"
  getfacl -p "$H/oth" | grep -q '^user:daemon:r--' && ok || bad "apply: the named entry of daemon was removed"
  getfacl -p "$H/keep" | grep -q '^default:' && ok || bad "apply: the keep-list tree lost its default ACL"
  getfacl -p -s "$H/skel" >/dev/null 2>&1; [ -z "$(getfacl -p -s "$H/skel" 2>/dev/null)" ] && ok || bad "apply: skel still has an ACL"
  touch "$H/skel/after"; expect "apply: a new file in the cleaned tree is 0644 (umask)" "644" "$(stat -c %a "$H/skel/after")"
  mkdir "$H/skel/newdir"; expect "apply: a new directory is 0755 (umask)" "755" "$(stat -c %a "$H/skel/newdir")"
  expect "apply: group bits follow the effective permission (r-- not r-x/rwx)" "640" "$(stat -c %a "$H/geff")"
  expect "apply: secret dir 0700" "700" "$(stat -c %a "$H/sec")"
  expect "apply: secret file 0600" "600" "$(stat -c %a "$H/sec/f644")"
  expect "apply: executable below a secret dir 0700" "700" "$(stat -c %a "$H/sec/dir/run")"
  expect "apply: top location 0700" "700" "$(stat -c %a "$H/sec2")"
  expect "apply: below a top location tightened once" "600" "$(stat -c %a "$H/sec2/file")"
  expect "apply: @REPO@ file 0700" "700" "$(stat -c %a "$REPOFIX/env.secret.sh")"
  expect "apply: the target of a symlink is not followed" "755" "$(stat -c %a "$H/outside")"
  expect "apply: path outside the secrets untouched" "644" "$(stat -c %a "$H/outside/f")"
  zcat "$ST"/home-acl-before-*.txt.gz 2>/dev/null | grep -q "^# file: $H/skel\$" && ok || bad "apply: the before-state does not hold the stripped paths"
  zcat "$ST"/home-acl-before-*.txt.gz 2>/dev/null | grep -q "^default:group::r-x" && ok || bad "apply: the before-state does not hold the default entries"
  grep -q "$H/sec/f644" "$ST"/secret-modes-before-*.txt 2>/dev/null && ok || bad "apply: no before-modes recorded"
  [ -e "$H/.local/state/usr/home-acl-cleanup" ] && ok || bad "apply: marker file missing"

  modes_after="$(find "$H" -xdev ! -type l -printf '%m %p\n' | sort)"
  again="$(ha apply)"
  case "$again" in *"unchanged: no unintended extended ACL"*"RESULT strip=0 tighten=0"*) ok ;; *) bad "apply is not idempotent: $(printf '%s\n' "$again" | tail -3 | paste -sd'|' -)" ;; esac
  expect "idempotent: modes identical to the first apply" "$modes_after" "$(find "$H" -xdev ! -type l -printf '%m %p\n' | sort)"

  chk="$(ha check)"
  case "$chk" in *"acl_count=0"*"mode_count=0"*"marker=1"*) ok ;; *) bad "home-acl check after apply: $(printf '%s' "$chk" | paste -sd' ' -)" ;; esac
  chmod 644 "$H/sec2/file"
  case "$(ha check)" in *"mode_count=0"*) ok ;; *) bad "check: a top location must only be judged on its own path" ;; esac
  chmod 755 "$H/sec2"
  case "$(ha check)" in *"mode_count=1"*) ok ;; *) bad "check: a wide top location is not reported" ;; esac
  chmod 700 "$H/sec2"; chmod 644 "$H/sec/f644"
  case "$(ha check)" in *"mode_count=1"*"~/sec/f644"*) ok ;; *) bad "check: a wide file in a full location is not reported" ;; esac
  chmod 600 "$H/sec/f644"
  mkdir -p "$H/late" && setfacl -d -m g::r-x,o::r-x,m::r-x "$H/late"
  case "$(ha check)" in *"acl_count=1"*"~/late"*) ok ;; *) bad "check: a new skeleton is not reported" ;; esac

  # rollback path: the saved before-state puts the skeletons back (what rollback.sh --home-acl-cleanup runs)
  (cd / && zcat "$ST"/home-acl-before-*.txt.gz | setfacl --restore=- 2>/dev/null)
  getfacl -p "$H/skel" 2>/dev/null | grep -q '^default:group::r-x' && ok || bad "rollback: the before-state does not restore the skeleton"
  ha apply >/dev/null
  [ -z "$(getfacl -p -s "$H/skel" 2>/dev/null)" ] && ok || bad "re-apply after the restore did not clean again"

  # ── FIX2: every change of the home runs as the owner, the marker never follows a symlink, restore, rollback ────────────
  # A fake runas prefix (--runas) logs what the script runs "as the owner"; root itself only writes the before-state.
  cat >"$T/fakebin/runas" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" | tr '\n' ' ' >>"$RUNAS_LOG"; printf '\n' >>"$RUNAS_LOG"
exec "$@"
FAKE
  chmod +x "$T/fakebin/runas"
  export RUNAS_LOG="$T/runas.log"
  H2="$T/aclhome2" ST2="$T/aclstate2"
  mkdir -p "$H2/skel" "$H2/oth" "$H2/sec" "$ST2"
  setfacl -d -m g::r-x,o::r-x,m::r-x "$H2/skel"
  setfacl -d -m u:daemon:rx "$H2/oth"                                      # somebody else's entry: kept and never in the before-state
  printf 's\n' >"$H2/sec/f"; chmod 644 "$H2/sec/f"
  printf 'sec full\n' >"$T/secrets2.txt"
  ha2() { "$HA" "$1" --root "$H2" --owner "$ME" --state "$ST2" --managed nobody --keep "$T/keep.txt" --secrets "$T/secrets2.txt" --repo "$REPOFIX" --runas "$T/fakebin/runas" "${@:2}" 2>&1; }
  : >"$RUNAS_LOG"
  out="$(ha2 apply)"
  grep -q 'xargs -0 -r setfacl -b' "$RUNAS_LOG" && ok || bad "FIX2 apply: setfacl -b does not run as the owner ($(paste -sd'|' "$RUNAS_LOG"))"
  grep -q 'xargs -0 -r chmod go-rwx' "$RUNAS_LOG" && ok || bad "FIX2 apply: chmod of the secret paths does not run as the owner"
  grep -q 'home-acl cleanup ran' "$RUNAS_LOG" && ok || bad "FIX2 apply: the marker is not written as the owner"
  grep -q 'chmod g=' "$RUNAS_LOG" && bad "FIX2 apply: the redundant chmod g= pass is back" || ok
  case "$out" in *"scanning $H2"*) ok ;; *) bad "FIX2 apply: no progress line before the scan" ;; esac
  # the before-state holds only the stripped paths
  zcat "$ST2"/home-acl-before-*.txt.gz | grep -q "^# file: $H2/skel\$" && ok || bad "FIX2 before-state: the stripped path is missing"
  zcat "$ST2"/home-acl-before-*.txt.gz | grep -q "^# file: $H2/oth\$" && bad "FIX2 before-state: holds a KEPT path (a restore would touch it)" || ok

  # a symlink planted where root used to chmod / chown / write: nothing outside is touched, marker refused or replaced
  H3="$T/aclhome3" ST3="$T/aclstate3"; VIC="$T/victim"
  mkdir -p "$H3/skel" "$H3/.local/state" "$VIC" "$ST3"; chmod 700 "$VIC"
  setfacl -d -m g::r-x,o::r-x,m::r-x "$H3/skel"
  ln -s "$VIC" "$H3/.local/state/usr"
  out="$("$HA" apply --root "$H3" --owner "$ME" --state "$ST3" --managed nobody --keep "$T/keep.txt" --secrets /dev/null --repo "$REPOFIX" 2>&1)"
  expect "FIX2 marker: the target of a symlinked state dir keeps its mode" "700" "$(stat -c %a "$VIC")"
  [ -z "$(ls -A "$VIC")" ] && ok || bad "FIX2 marker: a file was written through the symlinked directory"
  case "$out" in *"is a symlink, marker not written"*) ok ;; *) bad "FIX2 marker: no warning for the symlinked directory" ;; esac
  rm -f "$H3/.local/state/usr"; mkdir -p "$H3/.local/state/usr"
  printf 'precious\n' >"$T/precious"; ln -s "$T/precious" "$H3/.local/state/usr/home-acl-cleanup"
  "$HA" apply --root "$H3" --owner "$ME" --state "$ST3" --managed nobody --keep "$T/keep.txt" --secrets /dev/null --repo "$REPOFIX" >/dev/null 2>&1
  expect "FIX2 marker: a symlink as the marker file is replaced, not written through" "precious" "$(cat "$T/precious")"
  [ -f "$H3/.local/state/usr/home-acl-cleanup" ] && [ ! -L "$H3/.local/state/usr/home-acl-cleanup" ] && ok || bad "FIX2 marker: the marker is not a regular file after the replace"

  # a symlinked parent of a secret location leads nowhere: its real path leaves the home and the repo
  H4="$T/aclhome4"; OUT4="$T/outside4"
  mkdir -p "$H4/.config" "$OUT4/sub" "$ST3"; printf 'x\n' >"$OUT4/sub/f"; chmod 644 "$OUT4/sub/f"; chmod 755 "$OUT4/sub"
  ln -s "$OUT4" "$H4/.config/APP"
  printf '.config/APP/sub full\n' >"$T/secrets4.txt"
  out="$("$HA" report --root "$H4" --owner "$ME" --state "$ST3" --managed nobody --keep "$T/keep.txt" --secrets "$T/secrets4.txt" --repo "$REPOFIX" 2>&1)"
  case "$out" in *"tighten=0"*) ok ;; *) bad "FIX2 realpath: a symlinked parent of a secret location is followed ($(printf '%s\n' "$out" | tail -2 | paste -sd'|' -))" ;; esac
  case "$out" in *"skipped (the real path leaves the home"*) ok ;; *) bad "FIX2 realpath: the skipped location is not reported" ;; esac
  "$HA" apply --root "$H4" --owner "$ME" --state "$ST3" --managed nobody --keep "$T/keep.txt" --secrets "$T/secrets4.txt" --repo "$REPOFIX" >/dev/null 2>&1
  expect "FIX2 realpath: nothing outside the home was changed" "755 644" "$(stat -c %a "$OUT4/sub") $(stat -c %a "$OUT4/sub/f")"
  # a parent that is a symlink INTO the dotfiles checkout is fine (stow folding)
  mkdir -p "$REPOFIX/.config/APP2/d"; printf 'k\n' >"$REPOFIX/.config/APP2/d/f"; chmod 644 "$REPOFIX/.config/APP2/d/f"
  ln -s "$REPOFIX/.config/APP2" "$H4/.config/APP2"; printf '.config/APP2/d full\n' >"$T/secrets4b.txt"
  out="$("$HA" report --root "$H4" --owner "$ME" --state "$ST3" --managed nobody --keep "$T/keep.txt" --secrets "$T/secrets4b.txt" --repo "$REPOFIX" 2>&1)"
  case "$out" in *"tighten=2"*) ok ;; *) bad "FIX2 realpath: a location that resolves into the checkout is skipped" ;; esac

  # fresh files written by our own scripts are owner-only, so the doctor does not fail after the marker
  VS="$REPO/.config/hypr/scripts/vault.sh"
  printf '#!/bin/sh\nexit 0\n' >"$T/fakebin/notify-send"; chmod +x "$T/fakebin/notify-send"
  (umask 022; PATH="$T/fakebin:$PATH" XDG_STATE_HOME="$T/vstate" "$VS" ssh-agent on >/dev/null 2>&1)
  expect "FIX2 vault.sh ssh-agent on: state dir 0700, flag 0600" "700 600" "$(stat -c %a "$T/vstate/vault" 2>/dev/null) $(stat -c %a "$T/vstate/vault/ssh-agent" 2>/dev/null)"
  (umask 022; python3 -I -B - "$REPO/.local/bin/mcp-add" "$T/mstate" <<'PY'
import importlib.machinery, importlib.util, os, sys
os.environ["MCP_STATE_DIR"] = sys.argv[2]
loader = importlib.machinery.SourceFileLoader("mcp_add", sys.argv[1]); spec = importlib.util.spec_from_loader("mcp_add", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.do_claude = lambda *a, **k: True; m.do_codex = lambda *a, **k: True
m.gateway_servers = lambda *a, **k: ["x"]; m.stdio_servers = lambda *a, **k: []
m.main(["--no-legacy"])
PY
  ) >/dev/null 2>&1
  expect "FIX2 mcp-add: state dir 0700, mcp-added 0600" "700 600" "$(stat -c %a "$T/mstate" 2>/dev/null) $(stat -c %a "$T/mstate/mcp-added" 2>/dev/null)"
  # the shipped list: .ssh and obs-cmd are `top`, everything the cleanup judges `full` is written by our own scripts
  grep -E '^\.ssh( |$)' "$REPO/infrastructure/users/secret-paths.txt" | grep -q ' full' && bad "FIX2 secret-paths: .ssh is still full (ssh-keygen writes *.pub 0644)" || ok
  grep -E '^\.config/obs-cmd( |$)' "$REPO/infrastructure/users/secret-paths.txt" | grep -q ' full' && bad "FIX2 secret-paths: obs-cmd is still full" || ok

  # restore: oldest first, every snapshot, as the owner, owned paths only, symlinks never followed, no owner/group change
  H5="$T/aclhome5" ST5="$T/aclstate5"; OUT5="$T/outside5"
  mkdir -p "$H5/a" "$H5/b" "$H5/c" "$ST5" "$OUT5"
  chmod 700 "$H5/a" "$H5/b" "$H5/c"
  printf 'x\n' >"$H5/m1"; printf 'x\n' >"$H5/m2"; printf 'x\n' >"$H5/m3"; chmod 600 "$H5/m1" "$H5/m2" "$H5/m3"
  for d in a b; do setfacl -d -m g::r-x,o::r-x,m::r-x "$H5/$d"; getfacl -p -s "$H5/$d" >"$T/snap-$d.txt"; setfacl -b "$H5/$d"; done
  gzip -c "$T/snap-a.txt" >"$ST5/home-acl-before-20260101-000000.txt.gz"
  gzip -c "$T/snap-b.txt" >"$ST5/home-acl-before-20260102-000000.txt.gz"
  printf '755\t%s\n644\t%s\n644\t%s\n' "$H5/m1" "$H5/m3" "$H5/c" >"$ST5/secret-modes-before-20260101-000000.txt"
  printf '640\t%s\n600\t%s\n' "$H5/m2" "$H5/m3" >"$ST5/secret-modes-before-20260102-000000.txt"
  # a record of a path owned by root (/etc/hostname), one of a symlink to an outside file, one with a doctored owner line
  ln -s "$OUT5" "$H5/lnk"
  {
    printf '# file: /etc/hostname\n# owner: root\n# group: root\nuser::rw-\nuser:daemon:r--\ngroup::r--\nmask::r--\nother::r--\n\n'
    printf '# file: %s\n# owner: root\n# group: root\nuser::rwx\ngroup::r-x\nother::r-x\ndefault:user::rwx\ndefault:group::r-x\ndefault:other::r-x\n\n' "$H5/lnk"
    printf '# file: %s\n# owner: root\n# group: root\nuser::rwx\ngroup::r-x\nother::r-x\ndefault:user::rwx\ndefault:group::r-x\ndefault:other::r-x\n\n' "$H5/c"
  } | gzip -c >"$ST5/home-acl-before-20260103-000000.txt.gz"
  getfacl -p /etc/hostname 2>/dev/null >"$T/hostname.acl"
  mkdir -p "$H5/.local/state/usr"; : >"$H5/.local/state/usr/home-acl-cleanup"
  : >"$RUNAS_LOG"
  out="$("$HA" restore --root "$H5" --owner "$ME" --state "$ST5" --runas "$T/fakebin/runas" 2>&1)"
  for d in a b; do getfacl -p "$H5/$d" | grep -q '^default:group::r-x' && ok || bad "FIX2 restore: the skeleton of $d (snapshot $d) is not back ($(printf '%s' "$out" | paste -sd'|' -))"; done
  getfacl -p "$H5/c" | grep -q '^default:group::r-x' && ok || bad "FIX2 restore: a record with a doctored owner line was not applied"
  expect "FIX2 restore: group of c is not chown'd" "$(stat -c %G "$H5/a")" "$(stat -c %G "$H5/c")"
  [ -z "$(getfacl -p -s "$OUT5" 2>/dev/null)" ] && ok || bad "FIX2 restore: followed a symlink and changed its target"
  getfacl -p /etc/hostname 2>/dev/null | cmp -s - "$T/hostname.acl" && ok || bad "FIX2 restore: touched a path of another user"
  case "$out" in *"setfacl: "*) bad "FIX2 restore: setfacl complained ($(printf '%s' "$out" | grep 'setfacl:' | head -1))" ;; *) ok ;; esac
  expect "FIX2 restore: modes of snapshot 1 (m1)" "755" "$(stat -c %a "$H5/m1")"
  expect "FIX2 restore: modes of snapshot 2 (m2): every snapshot, not only the newest" "640" "$(stat -c %a "$H5/m2")"
  expect "FIX2 restore: oldest first, a later snapshot wins (m3)" "600" "$(stat -c %a "$H5/m3")"
  expect "FIX2 restore: mode of a dir (c)" "644" "$(stat -c %a "$H5/c")"
  [ -e "$H5/.local/state/usr/home-acl-cleanup" ] && bad "FIX2 restore: the marker is not removed" || ok
  grep -q 'setfacl --restore' "$RUNAS_LOG" && grep -q 'chmod' "$RUNAS_LOG" && ok || bad "FIX2 restore: setfacl/chmod do not run as the owner"

  # FIX3 F4: a restore retires the snapshots it used; a second restore must not replay them over what the owner changed since
  expect "FIX3 F4 restore: no snapshot is left in the state dir" "0" "$(ls "$ST5"/home-acl-before-*.txt.gz "$ST5"/secret-modes-before-*.txt 2>/dev/null | wc -l)"
  expect "FIX3 F4 restore: the 5 snapshot files were archived in restored-<time>/" "5" "$(ls "$ST5"/restored-*/ 2>/dev/null | grep -c 'before-')"
  chmod 600 "$H5/m1"; setfacl -b "$H5/a"
  out="$("$HA" restore --root "$H5" --owner "$ME" --state "$ST5" --runas "$T/fakebin/runas" 2>&1)"
  expect "FIX3 F4 restore: the second restore does not put m1 back to its first-snapshot mode" "600" "$(stat -c %a "$H5/m1")"
  [ -z "$(getfacl -p -s "$H5/a" 2>/dev/null)" ] && ok || bad "FIX3 F4 restore: the second restore replayed an old ACL snapshot"
  case "$out" in *"no home-acl-before-*.txt.gz"*"no secret-modes-before-"*) ok ;; *) bad "FIX3 F4 restore: the second restore does not say there is nothing left ($(printf '%s' "$out" | paste -sd'|' -))" ;; esac
  # the rollback tests below need a snapshot again (what the next `apply` would write)
  gzip -c "$T/snap-a.txt" >"$ST5/home-acl-before-20260104-000000.txt.gz"

  # FIX3 F6: root drops to the owner with setpriv (no PAM login stack like runuser) and starts in /
  H7="$T/aclhome7"; mkdir -p "$H7" "$T/st7"; printf 'x\n' >"$H7/m7"; chmod 600 "$H7/m7"
  printf '755\t%s\n' "$H7/m7" >"$T/st7/secret-modes-before-20260101-000000.txt"
  cat >"$T/fakebin/setpriv" <<'FAKE'
#!/bin/sh
echo "setpriv $* cwd=$(pwd) umask=$(umask)" >>"$SETPRIV_LOG"
reset=0; for a in "$@"; do [ "$a" = --reset-env ] && reset=1; done
while [ "$1" != -- ]; do shift; done; shift
# what setpriv --reset-env does to HOME / USER / LOGNAME (the fake uses SETPRIV_OWNER_HOME for the owner's passwd entry)
[ "$reset" = 1 ] && exec env HOME="$SETPRIV_OWNER_HOME" USER=owner LOGNAME=owner "$@"
exec "$@"
FAKE
  cat >"$T/fakebin/runuser" <<'FAKE'
#!/bin/sh
echo "runuser $*" >>"$SETPRIV_LOG"
exit 1
FAKE
  chmod +x "$T/fakebin/setpriv" "$T/fakebin/runuser"
  export SETPRIV_LOG="$T/setpriv.log" SETPRIV_OWNER_HOME="$T/owner-home"; : >"$SETPRIV_LOG"
  PATH="$T/fakebin:$PATH" HOME_ACL_TEST_EUID=0 "$HA" restore --root "$H7" --owner "$ME" --state "$T/st7" >/dev/null 2>&1
  grep -q "^setpriv --reuid=$(id -u) --regid=$(id -g) --init-groups --reset-env -- .* cwd=/ umask=0077\$" "$SETPRIV_LOG" && ok || bad "FIX3 F6 home-acl: root does not drop to the owner with setpriv --reuid --regid --init-groups --reset-env, umask 077, from / ($(head -2 "$SETPRIV_LOG" | paste -sd'|' -))"
  grep -q '^runuser' "$SETPRIV_LOG" && bad "FIX3 F6 home-acl: runuser (PAM login stack) is still used" || ok
  expect "FIX3 F6 home-acl: the change was made through setpriv (m7 mode)" "755" "$(stat -c %a "$H7/m7")"

  # rollback.sh --home-acl-cleanup runs alone: the sudoers rule and the managed users' ACL are not touched, no other option combines
  mkdir -p "$T/rb/etc/sudoers.d" "$T/rb/etc/polkit-1/rules.d" "$T/rb/srv/dotfiles"
  : >"$T/rb/etc/sudoers.d/50-usr-managed"; : >"$T/rb/etc/polkit-1/rules.d/50-usr-managed.rules"
  rb() { PATH="$T/fakebin:$PATH" FAKE_PASSWD_OWNER="$ME" FAKE_PASSWD_HOME="$H5" ROLLBACK_TEST=1 ROLLBACK_OWNER="$ME" ROLLBACK_STATE="$ST5" ROLLBACK_ETC="$T/rb" ROLLBACK_SRV="$T/rb" "$REPO/infrastructure/users/rollback.sh" "$@" 2>&1; }
  # the fake getent answers the owner with a home we choose (H5), every managed user as unknown
  cat >"$T/fakebin/getent" <<'FAKE'
#!/bin/sh
if [ "${1:-}" = passwd ] && [ -n "${2:-}" ]; then
  case "$2" in "$FAKE_PASSWD_OWNER") echo "$2:x:1000:1000::${FAKE_PASSWD_HOME:-/nonexistent}:/bin/sh"; exit 0 ;; root) exec /usr/bin/getent "$@" ;; *) exit 2 ;; esac
fi
exec /usr/bin/getent "$@"
FAKE
  mkdir -p "$H5/.local/state/usr"; : >"$H5/.local/state/usr/home-acl-cleanup"; setfacl -b "$H5/a"
  out="$(rb --home-acl-cleanup --srv)"; rc=$?
  expect "FIX2 rollback: --home-acl-cleanup combined with --srv is refused (exit 2)" "2" "$rc"
  [ -e "$T/rb/etc/sudoers.d/50-usr-managed" ] && ok || bad "FIX2 rollback: a refused combination removed the sudoers drop-in"
  out="$(rb --home-acl-cleanup)"; rc=$?
  expect "FIX2 rollback: --home-acl-cleanup alone succeeds" "0" "$rc"
  [ -e "$T/rb/etc/sudoers.d/50-usr-managed" ] && [ -e "$T/rb/etc/polkit-1/rules.d/50-usr-managed.rules" ] && ok || bad "FIX2 rollback: --home-acl-cleanup removed the sudoers/polkit files (it re-opens the home)"
  case "$out" in *"restoring the ACL entries of"*) bad "FIX2 rollback: --home-acl-cleanup ran the base rollback" ;; *) ok ;; esac
  getfacl -p "$H5/a" | grep -q '^default:group::r-x' && ok || bad "FIX2 rollback: --home-acl-cleanup did not restore the skeleton ($(printf '%s' "$out" | paste -sd'|' -))"
  out="$(rb)"; rc=$?
  expect "FIX2 rollback: the base rollback succeeds" "0" "$rc"
  [ -e "$T/rb/etc/sudoers.d/50-usr-managed" ] && bad "FIX2 rollback: the base rollback left the sudoers drop-in" || ok

  # UTF-8 names under the C locale are classified like any other (this getfacl prints them raw; the test pins that)
  H6="$T/aclhome6"; mkdir -p "$H6/Тест dir"; setfacl -d -m g::r-x,o::r-x,m::r-x "$H6/Тест dir"
  out="$(LC_ALL=C "$HA" report --root "$H6" --owner "$ME" --state "$ST3" --managed nobody --keep "$T/keep.txt" --secrets /dev/null --repo "$REPOFIX" 2>&1)"
  case "$out" in *"RESULT strip=1 "*) ok ;; *) bad "FIX2 utf-8: a Cyrillic directory name is not classified under LC_ALL=C ($(printf '%s' "$out" | tail -2 | paste -sd'|' -))" ;; esac
else
  printf 'skip  home ACL cleanup tests: no ACL support in %s\n' "${TMPDIR:-/tmp}"
fi

printf 'users tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
