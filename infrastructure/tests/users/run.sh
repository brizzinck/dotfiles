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
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "$T/safebin"
for tool in fzf-menu ghostty notify-send hyprctl wl-copy; do
  printf '#!/bin/sh\nexit 0\n' >"$T/safebin/$tool"
done
chmod +x "$T/safebin"/*
export PATH="$T/safebin:$PATH"
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
# Exercise the directory repair branches even when the host already has vault-share set up correctly.
# All other stat calls still inspect the real scratch fixtures.
cat >"$T/fakebin/stat" <<'FAKE'
#!/bin/sh
case "$*" in
  '-c %U:%G %a /run/vault-share' | '-c %U:%G %a /etc/vault-share')
    printf 'root:root 700\n'
    exit 0 ;;
esac
exec /usr/bin/stat "$@"
FAKE
chmod +x "$T/fakebin/stat"
mkdir -p "$T/dryhome/skel"
setfacl -d -m g::r-x,o::r-x,m::r-x "$T/dryhome/skel" 2>/dev/null
printf 'echo hi\n' >"$T/dryhome/leak.sh"
# BW-ORG: the owner's real overlay (company folder names) must never reach a test: VAULT_SHARE_LOCAL_SCOPES points at an invented one
printf 'td\tWork/Acme/**\nyc\tWork/Globex/**\n' >"$T/vs-local.tsv"
chmod 600 "$T/vs-local.tsv"
dry="$(PATH="$T/fakebin:$PATH" FAKE_PASSWD_OWNER="$ME" USERS_ACL_ROOT="$T/dryhome" VAULT_SHARE_LOCAL_SCOPES="$T/vs-local.tsv" "$REPO/apply-system.sh" --dry-run --only users 2>&1)"
case "$dry" in *"Runas_Alias USR_MANAGED = td, yc"*) ok ;; *) bad "sudoers Runas list is not td, yc" ;; esac
case "$dry" in *"var managed = [\"td\", \"yc\"];"*) ok ;; *) bad "polkit list is not td, yc" ;; esac
sudoers_rules="$(printf '%s\n' "$dry" | sed -n '/rendered .*50-usr-managed (mode/,/install -Dm440/p' | grep -E '\| (Runas_Alias|[a-z]+ ALL =)')"
case "$sudoers_rules" in *aimcp* | *root*) bad "sudoers rules name aimcp or root (nobecome / never root)" ;; *) ok ;; esac
polkit_rules="$(printf '%s\n' "$dry" | grep 'var managed =')"
case "$polkit_rules" in *aimcp* | *root*) bad "polkit list names aimcp or root" ;; *) ok ;; esac
case "$dry" in *"useradd -m -U -s /usr/bin/nologin -K HOME_MODE=0700 aimcp"*) ok ;; *) bad "dry run does not create the service user aimcp" ;; esac
case "$dry" in *"passwd -l aimcp"*) ok ;; *) bad "dry run does not lock aimcp's password" ;; esac
if printf '%s\n' "$dry" | grep -E '^\[dry-run\] useradd .* (td|yc)$' >/dev/null; then bad "dry run would create td or yc"; else ok; fi
# USERS-SYNC C1: /srv/devtools (the shared tool tree) and its .owner file are created next to /srv/dotfiles and /srv/nvim-shared
# (the real /srv/devtools exists after the owner applied the section: the dry run then says "unchanged", which is as good; M3)
case "$dry" in *"install -d -o $ME -g "*" -m 755 /srv/devtools"* | *"unchanged: /srv/devtools ($ME:"*" 755)"*) ok ;; *) bad "dry run does not create /srv/devtools (owner:owner 755)" ;; esac
case "$dry" in *"/dev/stdin /srv/devtools/.owner"* | *"unchanged: /srv/devtools/.owner ($ME)"*) ok ;; *) bad "dry run does not write /srv/devtools/.owner" ;; esac
case "$dry" in *"/dev/stdin /etc/usr-managed/devtools-owner"* | *"unchanged: /etc/usr-managed/devtools-owner ($ME)"*) ok ;; *) bad "dry run does not write the root-owned anchor /etc/usr-managed/devtools-owner (L2)" ;; esac
grep -q '/srv/devtools' "$REPO/infrastructure/users/rollback.sh" && bad "rollback.sh must not name /srv/devtools (it is data, never removed)" || ok
# BW-ORG C5: /run/vault-share (tmpfiles) and /etc/vault-share/scopes.tsv (rendered as the owner from the repo file + the overlay)
vsdry() { PATH="$T/fakebin:$PATH" FAKE_PASSWD_OWNER="$ME" USERS_ACL_ROOT="$T/dryhome" VAULT_SHARE_LOCAL_SCOPES="$1" "$REPO/apply-system.sh" --dry-run --only users 2>&1; }
vs_rules() { printf '%s\n' "$1" | sed -n '/rendered \/etc\/vault-share\/scopes.tsv/,/install -Dm640/p' | grep -P '^\s+\| [a-z]'; }
case "$dry" in *"| d /run/vault-share 0755 $ME "*" -"*) ok ;; *) bad "5.1 dry run does not render the tmpfiles rule d /run/vault-share 0755 OWNER GROUP" ;; esac
case "$dry" in *"systemd-tmpfiles --create /etc/tmpfiles.d/vault-share.conf"*) ok ;; *) bad "5.1 dry run does not run systemd-tmpfiles --create" ;; esac
vsr="$(vs_rules "$dry")"
for want in "td	Shared/**" "td	Users/td/**" "yc	Shared/**" "yc	Users/yc/**"; do
  case "$vsr" in *"| $want"*) ok ;; *) bad "5.2 rendered scopes lack: $want" ;; esac
done
case "$vsr" in *aimcp* | *tgconfirm* | *Linux*) bad "5.2 rendered scopes name a service user or Linux/..." ;; *) ok ;; esac
case "$vsr" in *"| td	Work/Acme/**"*"| yc	Work/Globex/**"*) ok ;; *) bad "5.3 the overlay rows (td Work/Acme/**, yc Work/Globex/**) are not in the scopes" ;; esac
case "$vsr" in *"| td	Work/Globex"* | *"| yc	Work/Acme"*) bad "5.3 an overlay row leaked to the other user" ;; *) ok ;; esac
case "$dry" in *"install -d -o root -g root -m 755 /etc/vault-share"*) ok ;; *) bad "5.2 dry run does not create /etc/vault-share (root:root 755)" ;; esac
# 5.4 an overlay that is group-writable or a symlink is ignored with a warning
cp "$T/vs-local.tsv" "$T/vs-gw.tsv"
chmod 660 "$T/vs-gw.tsv"
o="$(vsdry "$T/vs-gw.tsv")"
case "$o" in *"ignored: group- or other-writable"*) ok ;; *) bad "5.4 a group-writable overlay is not reported as ignored" ;; esac
case "$(vs_rules "$o")" in *Work/Acme*) bad "5.4 a group-writable overlay was still used" ;; *) ok ;; esac
ln -sf "$T/vs-local.tsv" "$T/vs-link.tsv"
o="$(vsdry "$T/vs-link.tsv")"
case "$(vs_rules "$o")" in *Work/Acme*) bad "5.4 a symlinked overlay was still used" ;; *) ok ;; esac
# 5.5 an invalid overlay row: the renderer prints nothing, the old file stays (no install of scopes.tsv)
printf 'td\t**\n' >"$T/vs-bad.tsv"
chmod 600 "$T/vs-bad.tsv"
o="$(vsdry "$T/vs-bad.tsv")"
case "$o" in *"install -Dm640"*"/etc/vault-share/scopes.tsv"*) bad "5.5 an invalid overlay still installs scopes.tsv" ;; *) ok ;; esac
case "$o" in *"vault-share/scopes.tsv failed its syntax check"* | *"scopes.tsv failed"*) ok ;; *) bad "5.5 an invalid overlay is not reported (the old file stays)" ;; esac
# 5.6 the real repo scopes.tsv renders and passes check-scopes
rendered="$(python3 -I -B "$REPO/.config/hypr/scripts/vault-share.py" render-scopes --repo "$REPO/infrastructure/vault-share/scopes.tsv" --managed "td yc" --owner "$ME" 2>&1)"
printf '%s\n' "$rendered" >"$T/real-scopes.tsv"
if python3 -I -B "$REPO/.config/hypr/scripts/vault-share.py" check-scopes "$T/real-scopes.tsv" --owner "$ME" >/dev/null 2>&1; then ok; else bad "5.6 the rendered repo scopes.tsv fails check-scopes"; fi
grep -q 'Work/' "$REPO/infrastructure/vault-share/scopes.tsv" && bad "5.6 the repo scopes.tsv names a company folder (they belong in the owner's local overlay)" || ok
# 5.7 rollback.sh removes the three vault-share paths and stops the socket (scratch tree, ROLLBACK_TEST)
mkdir -p "$T/rb7/etc/vault-share" "$T/rb7/etc/tmpfiles.d" "$T/rb7/run/vault-share" "$T/st7"
: >"$T/rb7/etc/vault-share/scopes.tsv"
: >"$T/rb7/etc/tmpfiles.d/vault-share.conf"
rb7="$(PATH="$T/fakebin:$PATH" FAKE_PASSWD_OWNER="$ME" FAKE_PASSWD_HOME="$T/dryhome" ROLLBACK_TEST=1 ROLLBACK_OWNER="$ME" ROLLBACK_STATE="$T/st7" ROLLBACK_ETC="$T/rb7" ROLLBACK_SRV="$T/rb7" "$REPO/infrastructure/users/rollback.sh" 2>&1)"
for want in "etc/tmpfiles.d/vault-share.conf" "etc/vault-share" "run/vault-share"; do
  case "$rb7" in *"removed $T/rb7/$want"*) ok ;; *) bad "5.7 rollback.sh did not remove /$want: $rb7" ;; esac
done
[ -e "$T/rb7/etc/vault-share" ] && bad "5.7 /etc/vault-share still exists after rollback" || ok

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
export USR_DEVTOOLS_SHARED="$T/no-devtools"   # a test must never start the real installer into the real /srv/devtools
mkdir -p "$T/srv" "$T/home"
export HOME="$T/home"
export XDG_STATE_HOME="$T/home/.local/state"
STATE_USR="$XDG_STATE_HOME/usr"
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
n_prof="$(grep -cvE '^[[:space:]]*(#|$)' "$REPO/infrastructure/users/profiles/cli.txt")"
case "$(run_link)" in *"0 linked, $n_prof already linked"*) ok ;; *) bad "second link run is not a no-op (profile has $n_prof entries)" ;; esac
# USERS-SYNC C4: the dev launchers and the tool configs are in the profile; tool directories stay real, only their files are links
for want in .local/bin/db .local/bin/api .local/bin/ci .local/bin/forge .config/devtools .config/posting/config.yaml .config/act/actrc .config/gh-dash/base.yml .config/envs/global.toml .config/lazydocker/config.yml; do
  grep -qx "$want" "$REPO/infrastructure/users/profiles/cli.txt" && ok || bad "cli profile does not list $want"
  [ -e "$T/srv/$want" ] && ok || bad "sync: $want is not published"
done
for f in .local/bin/db .local/bin/forge .config/devtools .config/posting/config.yaml .config/act/actrc .config/gh-dash/base.yml .config/envs/global.toml; do
  expect "td: ~/$f links into the published tree" "$T/srv/$f" "$(readlink "$T/h/td/$f")"
done
for d in .config/posting .config/act .config/gh-dash .config/envs .config/lazydocker; do
  [ -d "$T/h/td/$d" ] && [ ! -L "$T/h/td/$d" ] && ok || bad "td: ~/$d must stay a real directory (the tool writes next to the linked file)"
done
# the relative theme links of the repo break from /srv/dotfiles: usr link makes absolute ones into the user's own state; starting configs are copied once
expect "td: posting theme link" "$T/h/td/.local/state/theme/current/posting.yaml" "$(readlink "$T/h/td/.local/share/posting/themes/everforest.yaml")"
expect "td: glab-tui theme link" "$T/h/td/.local/state/theme/current/glab-tui.toml" "$(readlink "$T/h/td/.config/glab-tui/themes/everforest.toml")"
expect "td: btop theme link" "$T/h/td/.local/state/theme/current/btop.theme" "$(readlink "$T/h/td/.config/btop/themes/everforest-v2.theme")"
[ -f "$T/h/td/.config/glab-tui/config.toml" ] && [ ! -L "$T/h/td/.config/glab-tui/config.toml" ] && cmp -s "$T/h/td/.config/glab-tui/config.toml" "$REPO/infrastructure/dev/glab-tui-config.toml" && ok || bad "td: glab-tui config is not a copy of infrastructure/dev/glab-tui-config.toml"
[ -f "$T/h/td/.config/btop/btop.conf" ] && [ ! -L "$T/h/td/.config/btop/btop.conf" ] && ok || bad "td: btop.conf is not a copy"
echo "my own" >"$T/h/td/.config/glab-tui/config.toml"; echo "mine" >"$T/h/td/.config/btop/btop.conf"
rm -f "$T/h/td/.config/btop/themes/everforest-v2.theme"; echo "own theme" >"$T/h/td/.config/btop/themes/everforest-v2.theme"
run_link >/dev/null
expect "td: an existing glab-tui config is never overwritten" "my own" "$(cat "$T/h/td/.config/glab-tui/config.toml")"
expect "td: an existing btop.conf is never overwritten" "mine" "$(cat "$T/h/td/.config/btop/btop.conf")"
expect "td: a real file where a theme link would go is left alone" "own theme" "$(cat "$T/h/td/.config/btop/themes/everforest-v2.theme")"
rm -f "$T/h/td/.config/btop/themes/everforest-v2.theme"
# fzf-tab (L1): COPIED from the shared tree into oh-my-zsh's custom plugins (a link would be owned by another account: compaudit calls it
# insecure), with a marker holding the commit; an existing directory of the user (no marker) or a link of his own wins
FZP="$T/h/td/.oh-my-zsh/custom/plugins/fzf-tab"
mkdir -p "$T/dtfz/share/fzf-tab/lib" "$T/dtfz/share/fzf-tab/.git" "$T/h/td/.oh-my-zsh/custom/plugins"
echo '# plugin' >"$T/dtfz/share/fzf-tab/fzf-tab.plugin.zsh"; echo ref >"$T/dtfz/share/fzf-tab/.git/HEAD"; echo lib >"$T/dtfz/share/fzf-tab/lib/x.zsh"
printf 'stamp=x\nfzf-tab=c0ffee\n' >"$T/dtfz/.ready"
USR_DEVTOOLS_SHARED="$T/dtfz" run_link >/dev/null
[ -d "$FZP" ] && [ ! -L "$FZP" ] && [ -f "$FZP/fzf-tab.plugin.zsh" ] && [ -f "$FZP/lib/x.zsh" ] && ok || bad "td: fzf-tab is not a real copy of the shared plugin"
expect "td: the fzf-tab copy carries the commit marker, not the git dir" "c0ffee|no" "$(cat "$FZP/.from-devtools" 2>/dev/null)|$([ -e "$FZP/.git" ] && echo yes || echo no)"
printf 'stamp=x\nfzf-tab=beef01\n' >"$T/dtfz/.ready"
USR_DEVTOOLS_SHARED="$T/dtfz" run_link >/dev/null
expect "td: a new pinned commit refreshes the copy" "beef01" "$(cat "$FZP/.from-devtools" 2>/dev/null)"
rm -rf "$FZP"; ln -s "$T/dtfz/share/fzf-tab" "$FZP"   # what the earlier version of usr link made
USR_DEVTOOLS_SHARED="$T/dtfz" run_link >/dev/null
[ -d "$FZP" ] && [ ! -L "$FZP" ] && [ -f "$FZP/.from-devtools" ] && ok || bad "td: the old fzf-tab link was not replaced by a copy"
rm -rf "$FZP"; ln -s /nonexistent/own-fzf-tab "$FZP"
USR_DEVTOOLS_SHARED="$T/dtfz" run_link >/dev/null
expect "td: a link of his own at the fzf-tab place is left alone" "/nonexistent/own-fzf-tab" "$(readlink "$FZP")"
rm -f "$FZP"; mkdir "$FZP"
USR_DEVTOOLS_SHARED="$T/dtfz" run_link >/dev/null
[ -d "$FZP" ] && [ ! -L "$FZP" ] && [ ! -e "$FZP/.from-devtools" ] && ok || bad "td: an own fzf-tab directory was replaced"
# L5: a seed that replaces another link backs it up; --restore undoes exactly what the seeds made (and --dry-run restore changes nothing)
YH="$T/h/yc2"; mkdir -p "$YH/.oh-my-zsh/custom/plugins" "$YH/.config/btop/themes"
ln -s /elsewhere/x.theme "$YH/.config/btop/themes/everforest-v2.theme"
run_yc() { USR_DEVTOOLS_SHARED="$T/dtfz" USR_TARGET_USER=yc USR_TARGET_HOME="$YH" "$USR" _link "$@" 2>&1; }
out="$(run_yc)"
case "$out" in *"move   $YH/.config/btop/themes/everforest-v2.theme (link -> /elsewhere/x.theme) to the backup"*) ok ;; *) bad "a seed replaced a foreign link without announcing the backup: $out" ;; esac
expect "yc: the foreign theme link is in the backup" "/elsewhere/x.theme" "$(readlink "$YH"/.local/state/usr/backup-*/.config/btop/themes/everforest-v2.theme 2>/dev/null)"
grep -q "seed-link" "$YH"/.local/state/usr/backup-*/MANIFEST 2>/dev/null && ok || bad "the backup MANIFEST has no seed-link row"
expect "yc: the seeds are recorded for the restore (3 links, 2 copies, fzf-tab)" "6" "$(cut -f1 "$YH/.local/state/usr/seeds.tsv" | grep -c .)"
out="$(run_yc --restore --dry-run)"
[ -L "$YH/.zshrc" ] && [ -L "$YH/.local/share/posting/themes/everforest.yaml" ] && ok || bad "link --restore --dry-run removed links"
out="$(run_yc --restore)"
expect "yc restore: the foreign theme link is back" "/elsewhere/x.theme" "$(readlink "$YH/.config/btop/themes/everforest-v2.theme")"
for f in .local/share/posting/themes/everforest.yaml .config/glab-tui/themes/everforest.toml .config/glab-tui/config.toml .config/btop/btop.conf .oh-my-zsh/custom/plugins/fzf-tab .zshrc; do
  [ -e "$YH/$f" ] || [ -L "$YH/$f" ] && bad "yc restore left ~/$f behind" || ok
done
mkdir -p "$T/h/yc"
dry_yc="$(USR_TARGET_USER=yc USR_TARGET_HOME="$T/h/yc" "$USR" _link --dry-run 2>&1)"
case "$dry_yc" in *"link   $T/h/yc/.local/share/posting/themes/everforest.yaml -> $T/h/yc/.local/state/theme/current/posting.yaml"*"copy   "*"glab-tui-config.toml -> $T/h/yc/.config/glab-tui/config.toml"*) ok ;; *) bad "link --dry-run does not preview the seeded theme links and copies: $dry_yc" ;; esac
[ -e "$T/h/yc/.config" ] && bad "link --dry-run wrote into yc's home" || ok
# tmux: prefix+m (the owner-only hub) degrades to a message, the other dev binds call tools that are in the profile
grep -q "bind -N \"Utility hub popup (same list as SUPER+M)\" m if-shell 'test -x ~/.config/hub/hub' {" "$REPO/.config/tmux/tmux.conf" && ok || bad "tmux prefix+m has no fallback for a user without the hub"
grep -q 'ь if-shell "test -x ~/.config/hub/hub"' "$REPO/.config/tmux/tmux-layout.conf" && ok || bad "tmux-layout.conf twin of prefix+m is stale (layout.py gen tmux)"
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
(BW_SETUP_FAKE_OWNER="$(id -un)" FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY="" XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "FIX-DEVb2 #7: BW_SETUP_FAKE_OWNER naming the current user does not give the one-year timeout (the hook only shortens it)" "3600" "$(tail -1 "$T/pin.log.lock")"
(FAKE_PIN_LOG="$T/pin.log" PATH="$T/fakebin:$PATH" WAYLAND_DISPLAY="" XDG_RUNTIME_DIR="$T/run" "$REPO/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid </dev/null >/dev/null 2>&1)
expect "... and without the hook the owner still gets one year" "31536000" "$(tail -1 "$T/pin.log.lock")"
# FIX5 (review 15): the first `bw` sync of bw-setup reports a failure (it used to vanish silently: output to /dev/null, no else)
BT="$T/bwtree"; mkdir -p "$BT/.local/bin" "$BT/.config/hypr/scripts" "$BT/fb"
cp "$REPO/.local/bin/bw-setup" "$BT/.local/bin/bw-setup"
printf '#!/usr/bin/env python3\nimport os, sys\nsys.exit(int(os.environ.get("FAKE_SYNC_RC", "0")) if sys.argv[1] == "sync" else 0)\n' >"$BT/.config/hypr/scripts/vault-bw.py"
printf '#!/bin/sh\nexit 0\n' >"$BT/fb/rbw"; printf '#!/bin/sh\nexit 0\n' >"$BT/fb/pinentry-curses"
cat >"$BT/fb/bw" <<'BW'
#!/bin/sh
case "$1" in
  status) echo '{"status":"unauthenticated"}' ;;
  login) echo FAKESESSIONKEY ;;
esac
exit 0
BW
chmod +x "$BT/fb"/* "$BT/.local/bin/bw-setup"
bwset() { printf 'y\n' | FAKE_SYNC_RC=$1 PATH="$BT/fb:$PATH" WAYLAND_DISPLAY="" XDG_RUNTIME_DIR="$T/bwrun" "$BT/.local/bin/bw-setup" --url https://v.example.invalid --email t@example.invalid 2>&1; }
mkdir -p "$T/bwrun"; chmod 700 "$T/bwrun"
out="$(bwset 0)"
case "$out" in *"bw synced."*) ok ;; *) bad "bw-setup: a working sync says 'bw synced.' ($out)" ;; esac
out="$(bwset 1)"
case "$out" in *"bw sync failed"*"vault-bw.py sync"*) ok ;; *) bad "bw-setup: a failed first sync is reported (old code: silence) ($(printf '%s' "$out" | tail -3 | paste -sd'|'))" ;; esac
case "$out" in *"bw synced."*) bad "bw-setup: a failed sync must not say 'bw synced.'" ;; *) ok ;; esac
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
(cd "$T/rt" && python3 -I -B -c '
import socket, os
s = socket.socket(socket.AF_UNIX); s.bind("private-sock"); os.chmod("private-sock", 0o600)
os.makedirs("private-dir", mode=0o700)
')
USR_MANAGED_TSV="$T/clip.tsv" "$USR" clipboard-acl >/dev/null 2>&1
expect "clipboard: a 0600 socket and a 0700 directory keep their modes after a run (setfacl -m would widen the mask through the default group::rwx)" "600 700" "$(stat -c %a "$T/rt/private-sock" "$T/rt/private-dir" | paste -sd' ')"
expect "clipboard: ... and are denied" "user:nobody:---" "$(getfacl -p "$T/rt/private-sock" 2>/dev/null | grep '^user:nobody:')"
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

# ── USERS-SYNC C2: user-tools.sh --shared (dry-run argv, stamp, check) and usr devtools-sync ─────────────────────────────
UT="$REPO/infrastructure/dev/user-tools.sh"
DT="$T/devtools"
dtd="$("$UT" --shared --prefix "$DT" --dry-run 2>&1)"
for want in "env GOBIN=$DT/go/bin go install -trimpath github.com/jorgerojas26/lazysql@v0.7.0" "env GOBIN=$DT/go/bin go install -trimpath github.com/dlvhdr/gh-dash/v4@v4.26.2" \
  "/usr/bin/python3 -m venv --clear $DT/venv/posting" "-m pip install --disable-pip-version-check --require-hashes --no-deps -r $REPO/infrastructure/dev/posting-requirements.txt" \
  "npm install --prefix $DT/npm --ignore-scripts --no-audit --no-fund --no-save gitlab-ci-local@4.76.1" \
  "cargo install --locked --version 0.9.3 --root $DT/cargo glab-tui-crate" "cargo install --locked --version 0.1.276 --root $DT/cargo workmux" \
  "git clone --quiet https://github.com/Aloxaf/fzf-tab $DT/share/fzf-tab" "would link: $DT/bin/lazysql -> ../go/bin/lazysql" "would link: $DT/bin/posting -> ../venv/posting/bin/posting" "would link: $DT/bin/workmux -> ../cargo/bin/workmux"; do
  case "$dtd" in *"$want"*) ok ;; *) bad "user-tools.sh --shared --dry-run does not show: $want" ;; esac
done
[ -e "$DT" ] && bad "--shared --dry-run created $DT" || ok
case "$dtd" in *"npm install -g"* | *"pipx "* | *"sudo"*) bad "--shared must not use npm -g, pipx or sudo" ;; *) ok ;; esac
# the stamp follows the pins and the posting lock
st1="$("$UT" --shared --stamp)"
[ "${#st1}" = 64 ] && ok || bad "--stamp is not a sha256: $st1"
mkdir -p "$T/ut2/infrastructure/dev"
cp "$REPO/infrastructure/dev/"{user-tools.sh,posting-requirements.txt} "$T/ut2/infrastructure/dev/"
expect "stamp of an identical copy" "$st1" "$("$T/ut2/infrastructure/dev/user-tools.sh" --shared --stamp)"
sed -i 's/^WORKMUX_VERSION=0.1.276/WORKMUX_VERSION=0.1.277/' "$T/ut2/infrastructure/dev/user-tools.sh"
[ "$st1" != "$("$T/ut2/infrastructure/dev/user-tools.sh" --shared --stamp)" ] && ok || bad "a changed pin does not change the stamp"
cp "$REPO/infrastructure/dev/user-tools.sh" "$T/ut2/infrastructure/dev/user-tools.sh"
echo "# x" >>"$T/ut2/infrastructure/dev/posting-requirements.txt"
[ "$st1" != "$("$T/ut2/infrastructure/dev/user-tools.sh" --shared --stamp)" ] && ok || bad "a changed posting lock does not change the stamp"
# --check reads the installed versions (a fake go answers `go version -m`); only a matching, current tree passes
mkdir -p "$T/gobin" "$DT/go/bin"
cat >"$T/gobin/go" <<'FAKE'
#!/bin/sh
# fake go: `go version -m FILE` prints the module line the file's name maps to
[ "$1 $2" = "version -m" ] || exit 0
case "$3" in *lazysql) printf '\tmod\tgithub.com/jorgerojas26/lazysql\t%s\n' "${FAKE_LAZYSQL:-v0.7.0}" ;; esac
FAKE
chmod +x "$T/gobin/go"
printf '#!/bin/sh\n' >"$DT/go/bin/lazysql"; chmod +x "$DT/go/bin/lazysql"
out="$(PATH="$T/gobin:$PATH" "$UT" --shared --prefix "$DT" --only lazysql --check)"; rc=$?
expect "--check --only lazysql at the pin: exit 0, quiet" "0|" "$rc|$out"
out="$(PATH="$T/gobin:$PATH" FAKE_LAZYSQL=v0.6.0 "$UT" --shared --prefix "$DT" --only lazysql --check)"; rc=$?
expect "--check: an older lazysql is reported" "1|lazysql: 0.6.0 (pin 0.7.0)" "$rc|$out"
out="$(PATH="$T/gobin:$PATH" "$UT" --shared --prefix "$DT" --check)"; rc=$?
[ "$rc" = 1 ] && case "$out" in *"gh-dash: missing (pin 4.26.2)"*"posting: missing"*) true ;; *) false ;; esac && ok || bad "--check does not list the missing tools (rc $rc: $out)"
# a prefix that does not exist or is not writable: nothing is attempted, exit 1 with the fix
out="$("$UT" --shared --prefix "$T/not-there" 2>&1)"; rc=$?
[ "$rc" = 1 ] && case "$out" in *"sudo ./apply-system.sh --only users"*) true ;; *) false ;; esac && ok || bad "--shared on a missing prefix (rc $rc: $out)"
[ -e "$T/not-there" ] && bad "--shared created the missing prefix" || ok
"$UT" --shared --prefix relative/dir >/dev/null 2>&1; expect "--shared with a relative prefix is refused" 2 "$?"
"$UT" --check >/dev/null 2>&1; expect "--check without --shared is refused" 2 "$?"
# M1: two installers on one tree never overlap (the second waits, then finds the work done); L4: the build runs from /, without the
# caller's project environment or mise PATH entries
mkdir -p "$T/lockbin" "$T/locktree"
cat >"$T/lockbin/go" <<'FAKE'
#!/bin/sh
case "$1" in
  install) echo "start pwd=$(pwd) goflags=${GOFLAGS-unset} mise=${MISE_FOO-unset} path=$PATH" >>"$FAKE_GO_LOG"; sleep 1.2
    mkdir -p "$GOBIN"; : >"$GOBIN/lazysql"; chmod +x "$GOBIN/lazysql"; echo end >>"$FAKE_GO_LOG" ;;
  version) printf '\tmod\tgithub.com/jorgerojas26/lazysql\tv0.7.0\n' ;;
esac
FAKE
chmod +x "$T/lockbin/go"
export FAKE_GO_LOG="$T/go.log"; : >"$FAKE_GO_LOG"
for n in 1 2; do
  (cd "$T" && GOFLAGS=-mod=evil MISE_FOO=1 PATH="$T/lockbin:$T/fakehome/.local/share/mise/installs/node/20/bin:$PATH" "$UT" --shared --prefix "$T/locktree" --only lazysql >"$T/lock-$n.out" 2>&1; echo $? >"$T/lock-$n.rc") &
  sleep 0.4
done
wait
expect "user-tools --shared: two concurrent installs = one installer run (the second waits, then finds it current)" "1|1" "$(grep -c '^start' "$FAKE_GO_LOG")|$(grep -c '^end' "$FAKE_GO_LOG")"
expect "user-tools --shared: both runs exit 0" "0 0" "$(cat "$T/lock-1.rc") $(cat "$T/lock-2.rc")"
grep -q 'another --shared install holds' "$T/lock-2.out" && ok || bad "the second run did not say it waits for the lock ($(cat "$T/lock-2.out"))"
expect "user-tools --shared: the build runs from / with the project's variables and mise PATH entries removed" "start pwd=/ goflags=unset mise=unset path-ok" "$(sed -n 1p "$FAKE_GO_LOG" | sed -E 's/ path=.*mise\/installs.*/ path-mise/; s/ path=.*/ path-ok/')"
unset FAKE_GO_LOG
# L8/L4: --check never runs the venv's python, and a venv from a non-system python is not "installed"
PD="$T/posttree"; mkdir -p "$PD/bin" "$PD/venv/posting/bin" "$PD/venv/posting/lib/python3.14/site-packages/posting-2.11.1.dist-info"
printf '#!/bin/sh\ntouch "%s/ran"\n' "$T" >"$PD/venv/posting/bin/python"; chmod +x "$PD/venv/posting/bin/python"
printf '#!/bin/sh\n' >"$PD/venv/posting/bin/posting"; chmod +x "$PD/venv/posting/bin/posting"; ln -s ../venv/posting/bin/posting "$PD/bin/posting"
printf 'Name: posting\nVersion: 2.11.1\n' >"$PD/venv/posting/lib/python3.14/site-packages/posting-2.11.1.dist-info/METADATA"
sha256sum "$REPO/infrastructure/dev/posting-requirements.txt" | cut -d' ' -f1 >"$PD/venv/posting.lock"
printf 'home = /usr/bin\n' >"$PD/venv/posting/pyvenv.cfg"
"$UT" --shared --prefix "$PD" --only posting --check >/dev/null 2>&1; expect "--check posting: a venv on the system python at the pin is current" 0 "$?"
[ ! -e "$T/ran" ] && ok || bad "--check ran the venv's python as the owner"
printf 'home = /home/x/.local/share/mise/installs/python/3.12/bin\n' >"$PD/venv/posting/pyvenv.cfg"
"$UT" --shared --prefix "$PD" --only posting --check >/dev/null 2>&1; expect "--check posting: a venv built on another python is not current" 1 "$?"
# usr devtools-sync: a current tree is left alone, a stale one runs the installer (fake script) in the foreground / background
mkdir -p "$T/dtsync"
cat >"$T/fake-user-tools.sh" <<'FAKE'
#!/bin/sh
case " $* " in *" --stamp "*) echo "${FAKE_UT_STAMP:-stamp1}"; exit 0 ;; esac
echo "user-tools $*" >>"$FAKE_UT_LOG"
case " $* " in *" --check "*) exit "${FAKE_UT_CHECK:-1}" ;; esac
exit "${FAKE_UT_RC:-0}"
FAKE
chmod +x "$T/fake-user-tools.sh"
export FAKE_UT_LOG="$T/ut.log" USR_DEVTOOLS_SCRIPT="$T/fake-user-tools.sh"
: >"$FAKE_UT_LOG"
out="$(USR_DEVTOOLS_SHARED="$T/dtsync" FAKE_UT_CHECK=0 "$USR" devtools-sync 2>&1)"
case "$out" in *"up to date"*) ok ;; *) bad "devtools-sync on a current tree: $out" ;; esac
expect "devtools-sync: current tree = only the check ran" "user-tools --shared --prefix $T/dtsync --check" "$(cat "$FAKE_UT_LOG")"
: >"$FAKE_UT_LOG"
USR_DEVTOOLS_SHARED="$T/dtsync" "$USR" devtools-sync >/dev/null 2>&1; rc=$?
expect "devtools-sync: stale tree = installer ran, exit 0" "0|user-tools --shared --prefix $T/dtsync --check
user-tools --shared --prefix $T/dtsync" "$rc|$(cat "$FAKE_UT_LOG")"
USR_DEVTOOLS_SHARED="$T/dtsync" FAKE_UT_RC=1 "$USR" devtools-sync >/dev/null 2>&1; expect "devtools-sync: a failing installer = exit 1" 1 "$?"
USR_DEVTOOLS_SHARED="$T/no-dtsync" "$USR" devtools-sync >/dev/null 2>&1; expect "devtools-sync: no tree = refused (exit 2)" 2 "$?"
# `usr sync` starts it in the background only when the tree exists and is writable
rm -f "$STATE_USR/devtools-attempt.stamp"
: >"$FAKE_UT_LOG"
USR_DEVTOOLS_SHARED="$T/no-dtsync" "$USR" sync --worktree --quiet >/dev/null 2>&1
sleep 0.3; [ ! -s "$FAKE_UT_LOG" ] && ok || bad "usr sync ran the dev-tool installer without /srv/devtools: $(cat "$FAKE_UT_LOG")"
USR_DEVTOOLS_SHARED="$T/dtsync" "$USR" sync --worktree --quiet >/dev/null 2>&1
for _ in $(seq 40); do grep -q -- "--prefix $T/dtsync\$" "$FAKE_UT_LOG" && break; sleep 0.1; done
grep -qx "user-tools --shared --prefix $T/dtsync" "$FAKE_UT_LOG" && ok || bad "usr sync did not start devtools-sync in the background ($(cat "$FAKE_UT_LOG"))"
# M2: pins whose attempt just failed are not tried again by every commit: same stamp = no new run, new stamp or 6 h later = a run
sleep 0.3
runs() { grep -c -x "user-tools --shared --prefix $T/dtsync" "$FAKE_UT_LOG"; }
r1="$(runs)"
out="$(USR_DEVTOOLS_SHARED="$T/dtsync" "$USR" sync --worktree 2>&1)"; sleep 0.5
expect "usr sync: the same pins that just failed start no new installer run" "$r1" "$(runs)"
grep -q "last attempt for these pins" "$STATE_USR/sync.log" && ok || bad "usr sync does not log why it skipped the devtools install: $(tail -3 "$STATE_USR/sync.log")"
USR_DEVTOOLS_SHARED="$T/dtsync" FAKE_UT_STAMP=stamp2 "$USR" sync --worktree --quiet >/dev/null 2>&1
for _ in $(seq 30); do [ "$(runs)" -gt "$r1" ] && break; sleep 0.1; done
[ "$(runs)" -gt "$r1" ] && ok || bad "usr sync did not try again for new pins"
r1="$(runs)"; touch -d '7 hours ago' "$STATE_USR/devtools-attempt.stamp"
USR_DEVTOOLS_SHARED="$T/dtsync" FAKE_UT_STAMP=stamp2 "$USR" sync --worktree --quiet >/dev/null 2>&1
for _ in $(seq 30); do [ "$(runs)" -gt "$r1" ] && break; sleep 0.1; done
[ "$(runs)" -gt "$r1" ] && ok || bad "usr sync did not retry after the back-off"
r1="$(runs)"
USR_DEVTOOLS_SHARED="$T/dtsync" FAKE_UT_STAMP=stamp2 "$USR" devtools-sync >/dev/null 2>&1; sleep 0.2
[ "$(runs)" -gt "$r1" ] && ok || bad "a manual usr devtools-sync was throttled"
unset FAKE_UT_LOG USR_DEVTOOLS_SCRIPT

# ── USERS-SYNC C3: /srv/devtools/bin on a managed user's PATH and in the launchers' lookup, only while the tree is trusted ─────
# mk NAME: a fake shared tree owned by the owner (this user), .owner naming him; the "managed user" is a name / uid that is not him
mk_tree() { local d="$T/dtree-$1"; mkdir -p "$d/bin"; printf '%s\n' "$ME" >"$d/.owner"; chmod 755 "$d" "$d/bin"; chmod 644 "$d/.owner"; printf '#!/bin/sh\n' >"$d/bin/lazysql"; chmod 755 "$d/bin/lazysql"; : >"$d/.devtools-test"; echo "$d"; }
zpath() { # zpath ROOT USER -> position of ROOT/bin in PATH (0 = not there) as zsh sees it
  DF_DEVTOOLS_TEST=1 DF_DEVTOOLS_ROOT="$1" DF_DEVTOOLS_ME="$2" zsh -f -c "source '$REPO/.config/zsh/devtools.zsh'; print -r -- \${path[(Ie)$1/bin]}"
}
d="$(mk_tree a)"
[ "$(zpath "$d" td)" -gt 0 ] && ok || bad "zsh: a managed user does not get the trusted tree on PATH"
expect "zsh: the owner's PATH is unchanged" 0 "$(zpath "$d" "$ME")"
out="$(DF_DEVTOOLS_TEST=1 DF_DEVTOOLS_ROOT="$d" DF_DEVTOOLS_ME=td zsh -f -c "path=(/usr/bin /bin); source '$REPO/.config/zsh/devtools.zsh'; print -r -- \$path[-1]")"
expect "zsh: the tree is appended (the user's own installs win)" "$d/bin" "$out"
d="$(mk_tree b)"; chmod g+w "$d"; expect "zsh: group-writable root refused" 0 "$(zpath "$d" td)"
d="$(mk_tree c)"; chmod o+w "$d/bin"; expect "zsh: other-writable bin refused" 0 "$(zpath "$d" td)"
d="$(mk_tree d)"; echo nobody-else >"$d/.owner"; expect "zsh: .owner naming someone else refused" 0 "$(zpath "$d" td)"
d="$(mk_tree e)"; mv "$d/.owner" "$d/.owner.gone"; expect "zsh: no .owner refused" 0 "$(zpath "$d" td)"
d="$(mk_tree f)"; chmod 666 "$d/.owner"; expect "zsh: writable .owner refused" 0 "$(zpath "$d" td)"
d="$(mk_tree g)"; ln -s "$d" "$T/dtree-link"; expect "zsh: a symlinked root refused" 0 "$(zpath "$T/dtree-link" td)"
d="$(mk_tree h)"; mv "$d/bin" "$d/bin-x"; ln -s bin-x "$d/bin"; expect "zsh: a symlinked bin refused" 0 "$(zpath "$d" td)"
d="$(mk_tree i)"
expect "zsh: the hooks do nothing without DF_DEVTOOLS_TEST=1" 0 "$(DF_DEVTOOLS_ROOT="$d" DF_DEVTOOLS_ME=td zsh -f -c "source '$REPO/.config/zsh/devtools.zsh'; print -r -- \${path[(Ie)$d/bin]}")"
# L3: the hooks need a marker file in a tree below a temp directory; L2: the root-owned anchor decides who the owner is
d="$(mk_tree j)"; rm "$d/.devtools-test"; expect "zsh: the test hooks need the .devtools-test marker in the tree" 0 "$(zpath "$d" td)"
d="$(mk_tree k)"
zanchor() { DF_DEVTOOLS_TEST=1 DF_DEVTOOLS_ROOT="$1" DF_DEVTOOLS_ME="$2" DF_DEVTOOLS_ANCHOR="$3" zsh -f -c "source '$REPO/.config/zsh/devtools.zsh'; print -r -- \${path[(Ie)$1/bin]}"; }
printf '%s\n' "$ME" >"$T/anchor-ok"; chmod 644 "$T/anchor-ok"
[ "$(zanchor "$d" td "$T/anchor-ok")" -gt 0 ] && ok || bad "zsh: a tree owned by the account the anchor names is not used by a managed user"
expect "zsh: the account the anchor names does not use the tree" 0 "$(zanchor "$d" "$ME" "$T/anchor-ok")"
printf 'someone-else\n' >"$T/anchor-other"; chmod 644 "$T/anchor-other"
expect "zsh: a tree owned by an account the anchor does not name is refused" 0 "$(zanchor "$d" td "$T/anchor-other")"
chmod 666 "$T/anchor-other"; printf '%s\n' "$ME" >"$T/anchor-other"
expect "zsh: a writable anchor is refused" 0 "$(zanchor "$d" td "$T/anchor-other")"
expect "zsh: an anchor path that does not exist leaves the .owner rule" "$(zpath "$d" td)" "$(zanchor "$d" td "$T/no-anchor")"
# M4: login and non-interactive shells of a managed user (td's own .zshenv / .profile get a managed block from usr link)
LH="$T/h/login"; mkdir -p "$LH"
USR_TARGET_USER=td USR_TARGET_HOME="$LH" "$USR" _link >/dev/null 2>&1
grep -q '>>> usr:devtools >>>' "$LH/.zshenv" && grep -q '>>> usr:devtools >>>' "$LH/.profile" && ok || bad "usr link did not write the devtools blocks into .zshenv and .profile"
d="$(mk_tree l)"
lenv() { env -i HOME="$LH" PATH=/usr/bin:/bin DF_DEVTOOLS_TEST=1 DF_DEVTOOLS_ROOT="$d" DF_DEVTOOLS_ME=td "$@"; }
[ "$(lenv zsh -c "print -r -- \${path[(Ie)$d/bin]}")" -gt 0 ] && ok || bad "zsh -c (non-interactive) of a managed user does not get the shared tree"
[ "$(lenv zsh -lc "print -r -- \${path[(Ie)$d/bin]}")" -gt 0 ] && ok || bad "zsh -lc of a managed user does not get the shared tree"
case ":$(lenv bash -lc 'echo $PATH'):" in *":$d/bin:"*) ok ;; *) bad "bash -lc of a managed user does not get the shared tree" ;; esac
case ":$(lenv bash -lc 'echo $PATH' | tr -d '\n'):" in *"$d/bin:$d/bin"*) bad "bash -lc put the tree on PATH twice" ;; *) ok ;; esac
d2="$(mk_tree m)"
case ":$(env -i HOME="$LH" PATH=/usr/bin:/bin DF_DEVTOOLS_TEST=1 DF_DEVTOOLS_ROOT="$d2" DF_DEVTOOLS_ME="$ME" bash -lc 'echo $PATH'):" in *":$d2/bin:"*) bad "bash -lc of the owner got the tree" ;; *) ok ;; esac
expect "zsh: the real /srv/devtools is not used while it is absent" 0 "$(zsh -f -c "source '$REPO/.config/zsh/devtools.zsh'; print -r -- \${path[(Ie)/srv/devtools/bin]}")"
grep -q 'zsh/devtools.zsh' "$REPO/.zshrc" && ok || bad ".zshrc does not source zsh/devtools.zsh"
# the launchers' lookup (devtools.py): the same rule, in Python
out="$(python3 -I -B - "$REPO/.config/devtools" "$T" "$ME" <<'PY' 2>&1
import os, sys, stat
sys.path.insert(0, sys.argv[1])
import devtools as D
T, me = sys.argv[2], sys.argv[3]
mine = os.getuid()
def tree(n):
    d = f"{T}/pytree-{n}"; os.makedirs(f"{d}/bin"); os.chmod(d, 0o755); os.chmod(f"{d}/bin", 0o755)
    open(f"{d}/.owner", "w").write(me + "\n"); os.chmod(f"{d}/.owner", 0o644)
    open(f"{d}/bin/lazysql", "w").write("#!/bin/sh\n"); os.chmod(f"{d}/bin/lazysql", 0o755)
    return d
def r(label, got, want):
    print(f"{label}|{'ok' if got == want else f'FAIL got {got!r} want {want!r}'}")
d = tree("a")
r("py managed user gets the tree", D.shared_bin(d, me=mine + 12345), d + "/bin")
r("py owner does not", D.shared_bin(d, me=mine), None)
d = tree("b"); os.chmod(d, 0o775); r("py group-writable root", D.shared_bin(d, me=mine + 1), None)
d = tree("c"); os.chmod(d + "/bin", 0o757); r("py other-writable bin", D.shared_bin(d, me=mine + 1), None)
d = tree("d"); open(d + "/.owner", "w").write("root\n"); r("py .owner naming another account", D.shared_bin(d, me=mine + 1), None)
d = tree("e"); open(d + "/.owner", "w").write("no-such-account-xyz\n"); r("py .owner naming an unknown account", D.shared_bin(d, me=mine + 1), None)
d = tree("f"); os.rename(d + "/.owner", d + "/.owner.gone"); r("py no .owner", D.shared_bin(d, me=mine + 1), None)
d = tree("g"); os.chmod(d + "/.owner", 0o666); r("py writable .owner", D.shared_bin(d, me=mine + 1), None)
d = tree("h"); os.symlink(d, f"{T}/pylink"); r("py symlinked root", D.shared_bin(f"{T}/pylink", me=mine + 1), None)
d = tree("i"); os.rename(d + "/bin", d + "/bin-x"); os.symlink("bin-x", d + "/bin"); r("py symlinked bin", D.shared_bin(d, me=mine + 1), None)
r("py a missing root", D.shared_bin(f"{T}/pytree-none", me=mine + 1), None)
# L2: the root-owned anchor names the account that fills the tree
def anchor(name, mode=0o644):
    p = f"{T}/pyanchor-{name}"; open(p, "w").write(name + "\n"); os.chmod(p, mode); return p
d = tree("k")
r("py anchor naming the owner: a managed user gets the tree", D.shared_bin(d, me=mine + 1, anchor=anchor(me)), d + "/bin")
r("py anchor naming the owner: the owner does not", D.shared_bin(d, me=mine, anchor=anchor(me)), None)
r("py anchor naming another account: refused", D.shared_bin(d, me=mine + 1, anchor=anchor("root")), None)
r("py a writable anchor: refused", D.shared_bin(d, me=mine + 1, anchor=anchor(me + "x", 0o666)), None)
r("py an anchor that is not there: the .owner rule", D.shared_bin(d, me=mine + 1, anchor=f"{T}/pyanchor-none"), d + "/bin")
a2 = anchor("no-such-account-xyz")
r("py anchor naming an unknown account: refused", D.shared_bin(d, me=mine + 1, anchor=a2), None)
# _shared_tool: the file must really sit inside the tree and neither it nor its directories may be group/other-writable
d = tree("j")
D.shared_bin = lambda root=None, me=None, _d=d: _d + "/bin"
r("py tool inside the tree", D._shared_tool("lazysql"), d + "/bin/lazysql")
os.chmod(d + "/bin/lazysql", 0o775); r("py group-writable tool refused", D._shared_tool("lazysql"), None); os.chmod(d + "/bin/lazysql", 0o755)
open(f"{T}/outside-tool", "w").write("#!/bin/sh\n"); os.chmod(f"{T}/outside-tool", 0o755)
os.symlink(f"{T}/outside-tool", d + "/bin/evil"); r("py link leaving the tree refused", D._shared_tool("evil"), None)
os.makedirs(d + "/sub"); os.chmod(d + "/sub", 0o777); open(d + "/sub/t", "w").write("#!/bin/sh\n"); os.chmod(d + "/sub/t", 0o755); os.symlink("../sub/t", d + "/bin/viasub")
r("py tool below a writable directory refused", D._shared_tool("viasub"), None)
r("py a missing tool", D._shared_tool("nothing-here"), None)
PY
)"
while IFS='|' read -r label res; do
  [ -n "$label" ] || continue
  [ "$res" = ok ] && ok || bad "$label: $res"
done <<<"$out"
case "$out" in *"py tool inside the tree|ok"*) ;; *) bad "devtools.py harness did not run: $out" ;; esac
# a managed user's global.toml is a link into the published tree: accepted as the owner's file (not "owned by you"), other
# foreign files and a group-writable published file still refused; the owner's own checkout keeps the plain owner rule
mkdir -p "$T/pub/.local/bin" "$T/pub/.config/envs" "$T/h99/.config/envs"
cp "$REPO/.local/bin/envs" "$T/pub/.local/bin/envs"; chmod 755 "$T/pub" "$T/pub/.local" "$T/pub/.local/bin" "$T/pub/.config" "$T/pub/.config/envs"
printf 'project = "global"\n' >"$T/pub/.config/envs/global.toml"; chmod 644 "$T/pub/.config/envs/global.toml"
ln -sfn "$T/pub/.config/envs/global.toml" "$T/h99/.config/envs/global.toml"
printf 'project = "global"\n' >"$T/foreign.toml"; chmod 644 "$T/foreign.toml"
out="$(python3 -I -B - "$T/pub/.local/bin/envs" "$T" <<'PY' 2>&1
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("envs_pub", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("envs_pub", loader)); loader.exec_module(m)
T = sys.argv[2]
os.getuid = lambda: 99999          # the caller is a managed user: neither file belongs to uid 99999
def r(label, got, want):
    print(f"{label}|{'ok' if got == want else f'FAIL got {got!r} want {want!r}'}")
r("envs: link into the published tree is accepted (global.toml)", m._own_file_problem(f"{T}/h99/.config/envs/global.toml", allow_published=True), None)
r("envs: the same link is refused for any other file (global.local.toml; L7)", m._own_file_problem(f"{T}/h99/.config/envs/global.toml") is not None, True)
r("envs: a foreign file outside the published tree is refused", m._own_file_problem(f"{T}/foreign.toml") is not None, True)
os.chmod(f"{T}/pub/.config/envs/global.toml", 0o664)
r("envs: a group-writable published file is refused", "writable by group" in (m._own_file_problem(f"{T}/h99/.config/envs/global.toml", allow_published=True) or ""), True)
os.chmod(f"{T}/pub/.config/envs/global.toml", 0o644)
os.chmod(f"{T}/pub", 0o775)
r("envs: a group-writable published root is not trusted", m._own_file_problem(f"{T}/h99/.config/envs/global.toml", allow_published=True) is not None, True)
PY
)"
while IFS='|' read -r label res; do
  [ -n "$label" ] || continue
  [ "$res" = ok ] && ok || bad "$label: $res"
done <<<"$out"
case "$out" in *"link into the published tree is accepted (global.toml)|ok"*) ;; *) bad "envs published-file harness did not run: $out" ;; esac
# the launchers' runtime directory without a logind session (usr exec / sudo): a private /dev/shm directory, never a planted one
fb="/dev/shm/devtools-run-$(id -u)"
if [ ! -e "$fb" ] && [ ! -L "$fb" ] && [ -d /dev/shm ] && [ -w /dev/shm ]; then
  out="$(env -u XDG_RUNTIME_DIR python3 -I -B - "$REPO/.config/devtools" "$fb" "$T" <<'PY' 2>&1
import os, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import devtools as D
fb, T = sys.argv[2], sys.argv[3]
D.RUN_USER_DIR = f"{T}/no-run-user"            # no /run/user/UID
print("rb", D.runtime_base() == Path(fb), oct(os.stat(fb).st_mode & 0o777))
# L6: the job log ci-last.log ages out of the fallback after a day; a fresh one and other files stay
rr = D.run_root()
for n, age in (("ci-last.log", 90000), ("ci-new.log", 10), ("keep.txt", 90000)):
    (rr / n).write_text("x\n"); os.utime(rr / n, (time.time() - age,) * 2)
rr = D.run_root()
print("aged", sorted(x.name for x in rr.iterdir()))
os.chmod(fb, 0o755)
try:
    D.runtime_base(); print("loose ACCEPTED")
except D.DevError as e:
    print("loose refused")
PY
)"
  rm -rf "$fb" 2>/dev/null
  expect "devtools: no /run/user/UID = a private /dev/shm directory (ci-* ages out after a day), a loose one is refused" "rb True 0o700
aged ['ci-new.log', 'keep.txt']
loose refused" "$out"
  # a planted symlink at the fallback name is refused, and an explicitly set XDG_RUNTIME_DIR is used even when it is missing (L6)
  mkdir -p "$T/planted"; ln -s "$T/planted" "$fb"
  out="$(env -u XDG_RUNTIME_DIR python3 -I -B - "$REPO/.config/devtools" "$T" <<'PY' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import devtools as D
D.RUN_USER_DIR = f"{sys.argv[2]}/no-run-user"
try:
    D.runtime_base(); print("link ACCEPTED")
except D.DevError:
    print("link refused")
PY
)"
  rm -f "$fb"
  expect "devtools: a symlink planted at the /dev/shm fallback name is refused" "link refused" "$out"
  out="$(XDG_RUNTIME_DIR="$T/set-but-missing" python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import devtools as D; print(D.runtime_base())' "$REPO/.config/devtools" 2>&1)"
  expect "devtools: an explicit XDG_RUNTIME_DIR that does not exist is used, not replaced by /dev/shm" "$T/set-but-missing" "$out"
else
  printf 'skip  devtools runtime fallback test: %s exists or /dev/shm is not writable\n' "$fb"
fi
# the hints of a missing tool name the owner step for a managed account
grep -q 'managed_account' "$REPO/.config/devtools/devtools.py" && ok || bad "devtools.py has no managed_account()"

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
