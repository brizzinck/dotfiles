#!/usr/bin/env bash
# Offline tests of the managed-user stage (U7): registry parser, rendered sudoers/polkit, the usr helper in scratch directories
# (sync, profile links, clipboard ACL), vault-who's machinectl rule and nvim's shared-root choice. No sudo, no real user is
# touched (the scratch tree lives in $TMPDIR). Run: infrastructure/tests/users/run.sh [--quick]   (doctor runs --quick)
#   --quick   skips the nvim cases
set -u
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
out="$(python3 -I - "$REPO/.config/hypr/scripts/vault-who.py" <<'PY'
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
case "$(run_link)" in *"0 linked, 12 already linked"*) ok ;; *) bad "second link run is not a no-op" ;; esac
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
(cd "$T/rt" && python3 -I -c '
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
(cd "$T/rt" && python3 -I -c '
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
(cd "$T/rt2" && python3 -I -c '
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
else
  printf 'skip  home ACL cleanup tests: no ACL support in %s\n' "${TMPDIR:-/tmp}"
fi

printf 'users tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
