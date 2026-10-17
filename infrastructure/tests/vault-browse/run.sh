#!/usr/bin/env bash
# shellcheck disable=SC2016  # the check bodies are single-quoted on purpose: they run in their own bash -c
# Test of the vault browser (.config/hypr/scripts/vault-browse.py) against a fake rbw and a fake bw. The real vault is never
# touched: every tool the browser calls (rbw, bw, wl-copy, wl-paste, wtype, notify-send, hyprctl, pinentry, the editor) is a
# script in ./bin that keeps its state in a temp dir and logs its argv. The list is driven in a private tmux server.
#
#   run.sh            full run (about 2 minutes)
#   run.sh --quick    no tmux: rows, header, previews, masking (used by doctor.sh)
#   run.sh --keep     keep the temp dir (path printed at the end)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPTS="$REPO/.config/hypr/scripts"
BR="$SCRIPTS/vault-browse.py"
VAULT_SH="$SCRIPTS/vault.sh"
BIN="$HERE/bin"
QUICK=0 KEEP=0
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; *) echo "usage: run.sh [--quick] [--keep]" >&2; exit 2 ;; esac; done

FAKE=$(mktemp -d "${TMPDIR:-/tmp}/vault-browse-test.XXXXXX")
RUN="$FAKE/run"
SOCK="vbtest-$$"
T=(tmux -L "$SOCK")
export FAKE_DIR="$FAKE"
PASS=0 FAILS=0
SECRETS=('PW-github-s3cret!' 'TOKEN-api-hidden-777' '4111111111111111' 'CVV-secret-737' 'SSN-123-45-6789' 'PASSPORT-AB123456'
  'NOTE-secret-text' 'SSHPRIVATE-zzz' 'LINUXPASS-skalse-1' 'OLDPASS-1' 'master-pw' 'JBSWY3DPEHPK3PXP' 'PW-gitlab-pass'
  'PW-google-pass' 'PW-docs-pass' 'PW-old-forum' 'PW-tg-mcp-pass')

cleanup() {
  "${T[@]}" kill-server 2>/dev/null
  [[ -n ${SAMPLER:-} ]] && kill "$SAMPLER" 2>/dev/null
  if ((KEEP)); then echo "kept: $FAKE"; else rm -rf "$FAKE"; fi
}
trap cleanup EXIT

cat >"$FAKE/env.sh" <<ENV
export FAKE_DIR='$FAKE' XDG_RUNTIME_DIR='$RUN' PATH='$BIN':"\$PATH"
export RBW_BIN=rbw BW_BIN=bw PINENTRY_BIN='$BIN/pinentry' VAULT_RBW_CONF='$FAKE/rbw.json'
export EDITOR='$BIN/editor' VISUAL= VAULT_CLEAR_AFTER=2 BW_DOWNLOAD_DIR='$FAKE/dl'
export HYPRLAND_INSTANCE_SIGNATURE=fake VAULT_TERMINAL='$BIN/faketerm'
export FZF_MENU_NO_SERVER=1 VBTEST_TMUX='$SOCK'
unset TG_SKIP TMUX_PANE
ENV
echo '{"email":"test@example.com"}' >"$FAKE/rbw.json"

reset() { # [unlocked]: fresh vault and logs; "unlocked" starts with an open bw session
  "${T[@]}" kill-server 2>/dev/null
  rm -rf "$RUN" "$FAKE/dl" "$FAKE/state.json"
  mkdir -p "$RUN/vault" "$FAKE/dl"
  chmod 700 "$RUN" "$RUN/vault"
  cp "$HERE/fixture.json" "$FAKE/vault.json"
  rm -f "$FAKE"/{rbw-view.json,rbw-locked,bw-unlocked,seq,editor-calls,editor-script,editor.log,editor-input.json,pristine.json,typed.log,notify.log,\
clip.txt,clip.args,clip.events,app.log,last-*,term.log,gui-seq,gui-run.*,gui-done.*,gui.log}
  echo 0xAAA >"$FAKE/active"
  if [[ ${1:-} == unlocked ]]; then
    printf 'SESSION-KEY-abc' >"$RUN/vault/bw-session"
    chmod 600 "$RUN/vault/bw-session"
    touch "$FAKE/bw-unlocked"
  fi
}

# ───────────── helpers ─────────────
screen() {
  local out s
  out=$("${T[@]}" capture-pane -p -J -t t 2>/dev/null)
  for s in "${SECRETS[@]}"; do grep -aqF -- "$s" <<<"$out" && echo "$s" >>"$FAKE/leaks.log"; done
  printf '%s\n' "$out"
}
screen_has() { screen | grep -aqE -- "$1"; }
wait_for() { # REGEX [seconds]
  local i max=$(( ${2:-8} * 5 ))
  for ((i = 0; i < max; i++)); do screen_has "$1" && return 0; sleep 0.2; done
  return 1
}
gone() { ! screen_has "$1"; }
wait_gone() {
  local i
  for ((i = 0; i < 25; i++)); do screen_has "$1" || return 0; sleep 0.2; done
  return 1
}
k() { local x; for x in "$@"; do "${T[@]}" send-keys -t t "$x"; sleep 0.15; done; }
lit() { "${T[@]}" send-keys -t t -l "$1"; sleep 0.15; }
start() {
  "${T[@]}" new-session -d -s t -x 150 -y 42 "bash --noprofile --norc -c '. $FAKE/env.sh; $VAULT_SH browse --here $*; echo EXIT[\$?]; sleep 40'"
  wait_for 'Folder: ' 15
}
startgui() { # like start, but without a tty: the menu and the terminal steps open as (fake) ghostty windows
  "${T[@]}" new-session -d -s t -x 150 -y 42 "bash --noprofile --norc -c '. $FAKE/env.sh; export VAULT_TERMINAL=\"$BIN/ghostty --class=float.tui --title=vault -e\"; $VAULT_SH browse </dev/null; echo EXIT[\$?]; sleep 40'"
  wait_for 'Folder: ' 15
  sleep 0.5
  k C-l   # the first key typed into a freshly opened tmux window is swallowed (harness artifact): spend a harmless one
}
file_has() { grep -aqE -- "$2" "$1" 2>/dev/null; }
file_eq() { [[ $(cat "$1" 2>/dev/null) == "$2" ]]; }
wait_file() { # FILE REGEX [seconds]
  local i max=$(( ${3:-8} * 5 ))
  for ((i = 0; i < max; i++)); do file_has "$1" "$2" && return 0; sleep 0.2; done
  return 1
}
mark() { ARGV_MARK=$(wc -l <"$FAKE/argv.log" 2>/dev/null || echo 0); }
argv_since() { tail -n +"$((ARGV_MARK + 1))" "$FAKE/argv.log"; }
argv_has() { argv_since | grep -aqE -- "$1"; }
vjq() { jq -r "$1" "$FAKE/vault.json"; }
check() { # NAME CMD...
  local name=$1
  shift
  if "$@"; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$name"; else FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$name"; fi
}
dump() { echo '--- screen ---'; screen; echo '--- notify ---'; cat "$FAKE/notify.log" 2>/dev/null; echo '--- end ---'; }

# ───────────── quick checks (no tmux) ─────────────
quick() {
  local out st="$FAKE/state.json" i
  reset
  # shellcheck disable=SC1091
  . "$FAKE/env.sh"
  export VAULT_BROWSE_STATE="$st"
  out=$(python3 -I "$BR" rows)
  check "rows: every non-trashed item, no secret" bash -c '[ "$(grep -c "^i-" <<<"$1")" = 10 ] && ! grep -q "PW-" <<<"$1"' _ "$out"
  check "rows: Open-the-app hint row" grep -q '^@app' <<<"$out"
  check "rows: type tags (card, id, note, ssh)" bash -c 'grep -q "Visa.*card" <<<"$1" && grep -q "Passport.*id" <<<"$1" && grep -q "Wi-Fi.*note" <<<"$1" && grep -q "deploy.*ssh" <<<"$1"' _ "$out"
  out=$(python3 -I "$BR" header --cycle next >/dev/null; python3 -I "$BR" rows | sed 's/\x1b\[[0-9;]*m//g')
  check "rows --cycle next: first folder (Linux)" bash -c 'grep -q "^i-skalse" <<<"$1" && ! grep -q "github" <<<"$1"' _ "$out"
  check "header: folder and keys" bash -c 'python3 -I "$1" header | grep -q "Folder: Linux (2/" ' _ "$BR"
  for i in 1 2 3; do python3 -I "$BR" header --cycle next >/dev/null; python3 -I "$BR" rows >/dev/null; done
  out=$(python3 -I "$BR" header --cycle next >/dev/null; python3 -I "$BR" rows)
  check "trash with bw locked: unlock hint row" grep -q '^@unlock' <<<"$out"
  out=$(python3 -I "$BR" preview i-github | sed 's/\x1b\[[0-9;]*m//g')
  check "preview login: user shown" grep -q 'brizzinck' <<<"$out"
  check "preview login: password masked" bash -c 'grep -q "pass *••••••••" <<<"$1" && ! grep -q "PW-github" <<<"$1"' _ "$out"
  check "preview login: live TOTP and seconds left" grep -qE '[0-9]{3} [0-9]{3} \([0-9]+s\)' <<<"$out"
  check "preview login: hidden field masked, text field shown" bash -c 'grep -q "api_key *••••••••" <<<"$1" && ! grep -q "TOKEN-api" <<<"$1" && grep -q "region *eu-north" <<<"$1"' _ "$out"
  check "preview login: URL" grep -q 'https://github.com' <<<"$out"
  out=$(python3 -I "$BR" preview i-visa | sed 's/\x1b\[[0-9;]*m//g')
  check "preview card: last 4 only, cvv masked" bash -c 'grep -q "•••• 1111" <<<"$1" && ! grep -q "4111111111111111" <<<"$1" && ! grep -q "CVV-secret" <<<"$1" && grep -q "12/2030" <<<"$1"' _ "$out"
  out=$(python3 -I "$BR" preview i-passport | sed 's/\x1b\[[0-9;]*m//g')
  check "preview identity: ssn / passport masked" bash -c '! grep -q "SSN-123" <<<"$1" && ! grep -q "PASSPORT-AB" <<<"$1" && grep -q "Kyiv" <<<"$1"' _ "$out"
  out=$(python3 -I "$BR" preview i-wifi | sed 's/\x1b\[[0-9;]*m//g')
  check "preview note: text masked, line count shown" bash -c '! grep -q "NOTE-secret" <<<"$1" && grep -q "2 lines" <<<"$1"' _ "$out"
  out=$(python3 -I "$BR" preview i-deploy | sed 's/\x1b\[[0-9;]*m//g')
  check "preview ssh key: fingerprint and public key, private masked" bash -c 'grep -q "SHA256:fingerprintOK" <<<"$1" && grep -q "ssh-ed25519" <<<"$1" && ! grep -q "SSHPRIVATE" <<<"$1"' _ "$out"
  # an open bw session adds attachments and the trash to the preview
  reset unlocked
  export VAULT_BROWSE_STATE="$st"
  for i in 1 2 3 4; do python3 -I "$BR" header --cycle next >/dev/null; python3 -I "$BR" rows >/dev/null; done
  out=$(python3 -I "$BR" header --cycle next >/dev/null; python3 -I "$BR" rows | sed 's/\x1b\[[0-9;]*m//g')
  check "trash view lists the trashed item" grep -q 'old-forum' <<<"$out"
  out=$(python3 -I "$BR" preview i-docs | sed 's/\x1b\[[0-9;]*m//g')
  check "index: attachments in the preview (bw open)" grep -q 'report.pdf (11 Bytes)' <<<"$out"
  check "index file: mode 600 and no secret" bash -c '[ "$(stat -c %a "$1")" = 600 ] && ! grep -qE "PW-|TOKEN-api|4111111111111111|SSHPRIVATE|JBSWY3DP" "$1"' _ "$RUN/vault/browse-index.json"
  out=$(python3 -I "$BR" preview i-old | sed 's/\x1b\[[0-9;]*m//g')
  check "preview of a trashed item: masked, deletion date, hint" bash -c 'grep -q "in the trash since 2026-09-30" <<<"$1" && ! grep -q "PW-old" <<<"$1" && grep -q "r restores" <<<"$1"' _ "$out"
  # the terminal runner outside a tty: VAULT_TERMINAL gets the `_act` command, bw edits the vault
  : >"$FAKE/editor-script"
  echo '.name = "Fresh SSH" | .sshKey.privateKey = "x"' >"$FAKE/editor-script"
  python3 -I -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('vb', '$BR'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.run_tui('new-tpl', 'ssh', 'Work')" >/dev/null 2>&1
  check "run_tui without a tty goes through VAULT_TERMINAL" file_has "$FAKE/term.log" '_act new-tpl ssh Work'
  check "new SSH key (template fallback) created in the folder" bash -c '[ "$(jq -r ".items[] | select(.name==\"Fresh SSH\") | .folderId" "$1")" = f-work ]' _ "$FAKE/vault.json"
  check "editor file was 600 in a 700 directory" file_has "$FAKE/editor.log" 'file 600 dir 700'
  check "edit file is gone (shredded)" bash -c '! ls "$1"/vault/edit/*.json 2>/dev/null | grep -q .' _ "$RUN"
}

quick

if ((QUICK)); then
  printf '\nvault-browse quick test: %d passed, %d failed\n' "$PASS" "$FAILS"
  ((FAILS == 0))
  exit $?
fi

# ───────────── driven cases (private tmux) ─────────────
# every 50 ms: the command lines of every process that handles vault data (the fakes, the scripts, fzf, python); the
# harness' own bash/grep/jq processes are left out because their arguments are the test's expected values
# shellcheck disable=SC2009  # pgrep cannot print the full argument list this check needs
( while true; do ps -eo comm=,args= | grep -aE '^(rbw|bw|wl-copy|wl-paste|wtype|notify-send|fzf|fzf-menu|python3|editor|pinentry|vault\.sh|shred|curl) ' ; sleep 0.05; done ) >>"$FAKE/ps.log" 2>/dev/null &
SAMPLER=$!
: >"$FAKE/argv.log"

quit_menu() { k Escape Escape; wait_for 'EXIT\[0\]' 5; }

# 1. list, header, folders
s1() {
reset
start
check "list: header shows the folder and keys" screen_has 'Folder: All \(1/6\).*Tab'
check "list: items with folders and type tags" bash -c 'screen=$1; grep -q "github.com" <<<"$screen" && grep -qE "Visa travel .*card" <<<"$screen" && grep -qE "deploy-key .*ssh" <<<"$screen"' _ "$(screen)"
check "list: open-the-app hint row" screen_has 'Open the Bitwarden app'
check "list: 11 rows (10 items + hint)" screen_has '11/11'
check "header: bw locked hint" screen_has 'bw locked'
lit github
check "preview: user, masked password, TOTP with seconds, URL" bash -c 's=$1; grep -q brizzinck <<<"$s" && grep -q "pass *••••••••" <<<"$s" && grep -qE "[0-9]{3} [0-9]{3} \([0-9]+s\)" <<<"$s" && grep -q https://github.com <<<"$s"' _ "$(sleep 1; screen)"
check "preview: hidden field masked, text field shown" bash -c 's=$1; grep -q "api_key *••••••••" <<<"$s" && grep -q "region *eu-north" <<<"$s"' _ "$(screen)"
t1=$(screen | grep -aoE '[0-9]{3} [0-9]{3} \([0-9]+s\)' | head -1); sleep 2.2; t2=$(screen | grep -aoE '[0-9]{3} [0-9]{3} \([0-9]+s\)' | head -1)
check "preview ticks every second (live countdown)" test "$t1" != "$t2"
k Escape; lit c
k Tab
check "Tab: next folder (Linux) with its items only" bash -c 'wait=0; s=$1; grep -q "Folder: Linux (2/6)" <<<"$s" && grep -q skalse <<<"$s" && ! grep -q github.com <<<"$s"' _ "$(sleep 1; screen)"
k Tab Tab
check "Tab: Work folder (3 items)" bash -c 's=$1; grep -q "Folder: Work (4/6)" <<<"$s" && grep -q "gitlab.yacode.dev" <<<"$s" && grep -q deploy-key <<<"$s" && ! grep -q google.com <<<"$s"' _ "$(sleep 1; screen)"
k BTab
check "Shift+Tab: previous folder" bash -c 's=$1; grep -q "Folder: MCP (3/6)" <<<"$s" && grep -q telegram-mcp <<<"$s"' _ "$(sleep 1; screen)"
k Tab Tab Tab
check "Tab: wraps through (no folder) to Trash; bw locked row" bash -c 's=$1; grep -q "Folder: Trash (6/6)" <<<"$s" && grep -q "bw CLI is locked" <<<"$s"' _ "$(sleep 1.5; screen)"
mark
k Enter
check "Enter on the locked-trash row unlocks bw (pinentry) and lists the trash" wait_for 'old-forum' 10
check "  bw session file written, mode 600" bash -c '[ "$(stat -c %a "$1")" = 600 ]' _ "$RUN/vault/bw-session"
check "  header no longer says bw locked" gone 'bw locked'
check "  preview of a trashed item: masked + hint" bash -c 's=$1; grep -q "in the trash since 2026-09-30" <<<"$s" && grep -q "r restores" <<<"$s"' _ "$(sleep 1; screen)"
quit_menu
check "Esc Esc quits cleanly" screen_has 'EXIT\[0\]'
}

# 2. copy actions (NORMAL letters, Alt keys, Cyrillic twin)
s2() {
reset
start
lit github; sleep 0.5
mark
k Escape; lit y
check "y: password copied, sensitive" bash -c 'wait=1; sleep 1.2; [ "$(cat "$1/clip.txt")" = "PW-github-s3cret!" ] && grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
check "y: notification names the item, never the secret" bash -c 'grep -q "Password copied" "$1/notify.log" && ! grep -q "PW-github" "$1/notify.log"' _ "$FAKE"
check "y: browser exits after a copy" wait_for 'EXIT\[0\]' 5
check "y: clipboard cleared after VAULT_CLEAR_AFTER" wait_file "$FAKE/clip.events" '^cleared' 6
reset
start
lit github; sleep 0.5
k M-u
check "Alt+u (INSERT mode): user name copied, plain clipboard" bash -c 'sleep 1; [ "$(cat "$1/clip.txt")" = brizzinck ] && ! grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
reset
start
lit github; sleep 0.5
k Escape; lit o
check "o: TOTP code copied (6 digits), sensitive" bash -c 'sleep 1; grep -qE "^[0-9]{6}$" "$1/clip.txt" && grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
check "o: notification gives seconds left, not the code" bash -c 'grep -q "valid for" "$1/notify.log" && ! grep -qE "[0-9]{6}" "$1/notify.log"' _ "$FAKE"
reset
start
lit github; sleep 0.5
k Escape; lit н
check "Cyrillic twin of y (н) copies the password" bash -c 'sleep 1.2; [ "$(cat "$1/clip.txt")" = "PW-github-s3cret!" ]' _ "$FAKE"
reset
start
lit github; sleep 0.5
k M-f
check "Alt+f: field picker (masked values)" wait_for 'field>.*'
check "  picker rows are masked" bash -c 's=$1; grep -q "api_key *••••••••" <<<"$s" && grep -q "region *eu-north" <<<"$s" && grep -q "totp *live code" <<<"$s"' _ "$(screen)"
lit api; sleep 0.4; k Enter
check "  hidden custom field copied sensitive" bash -c 'sleep 1; [ "$(cat "$1/clip.txt")" = TOKEN-api-hidden-777 ] && grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
reset
start
lit github; sleep 0.5
k Escape; lit f; sleep 0.8; lit region; sleep 0.4; k Enter
check "f: a plain text field is copied without --sensitive" bash -c 'sleep 1; [ "$(cat "$1/clip.txt")" = eu-north ] && ! grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
}

# 3. other item types: primary secret per type, Enter = field picker
s3() {
for case in 'Visa|4111111111111111|card number' 'Wi-Fi|NOTE-secret-text|note text' 'deploy-key|SSHPRIVATE-zzz|SSH private key'; do
  IFS='|' read -r q want what <<<"$case"
  reset
  start
  lit "$q"; sleep 0.5
  k Escape; lit y
  check "y on $what" bash -c 'sleep 1.2; grep -qF -- "$2" "$1/clip.txt" && grep -q -- --sensitive "$1/clip.args"' _ "$FAKE" "$want"
done
reset
start
lit Visa; sleep 0.5; k Enter
check "Enter on a card: field picker, number shows the last 4 only" bash -c 's=$1; grep -q "number *•••• 1111" <<<"$s" && grep -q "cvv *••••••••" <<<"$s"' _ "$(sleep 1; screen)"
lit cvv; sleep 0.4; k Enter
check "  cvv copied sensitive" bash -c 'sleep 1; [ "$(cat "$1/clip.txt")" = CVV-secret-737 ]' _ "$FAKE"
reset
start
lit Passport; sleep 0.5; k Escape; lit y
check "y on an identity (no primary secret): picker with masked ssn" bash -c 's=$1; grep -q "ssn *••••••••" <<<"$s" && grep -q "address *Main 1, Kyiv, UA" <<<"$s"' _ "$(sleep 1; screen)"
k Escape Escape; sleep 0.5; k Escape Escape
}

# 4. typing (guard)
s4() {
reset
start
lit github; sleep 0.5; k Escape; lit t
check "t: user, Tab, password typed with wtype from stdin" bash -c 'sleep 1.5; [ "$(cat "$1/typed.log")" = "$(printf "TEXT:brizzinck\nKEY:-k Tab\nTEXT:PW-github-s3cret!")" ]' _ "$FAKE"
check "  wtype argv never holds the text" bash -c '! grep -E "^wtype .*(brizzinck|PW-)" "$1/argv.log"' _ "$FAKE"
reset
start
lit github; sleep 0.5; k Enter
check "Enter on a login types it too" bash -c 'sleep 1.5; grep -q "TEXT:PW-github-s3cret!" "$1/typed.log"' _ "$FAKE"
reset
start
lit github; sleep 0.5; k M-p
check "Alt+p: password only (no user, no Tab)" bash -c 'sleep 1.5; [ "$(cat "$1/typed.log")" = "TEXT:PW-github-s3cret!" ]' _ "$FAKE"
reset
start
lit github; sleep 0.5
echo 0xBBB >"$FAKE/active"
k Escape; lit t
check "guard: focus moved since the browser opened -> nothing typed" bash -c 'sleep 1.5; [ ! -s "$1/typed.log" ] && grep -q "Focus changed" "$1/notify.log"' _ "$FAKE"
quit_menu
reset
start
lit Visa; sleep 0.5; k Escape; lit t
check "t on a card: refused with a hint, nothing typed" bash -c 'sleep 1.5; [ ! -s "$1/typed.log" ] && grep -q "Only logins" "$1/notify.log"' _ "$FAKE"
quit_menu
}

# 5. edit (bw): 600 tmpfs file, validated, folder by name, rbw sync, shredded
s5() {
reset
start
lit github; sleep 0.5
printf '%s\n' 'BAD' '.name = "github.com edited" | ._folder = "MCP" | .login.username = "brizz2"' >"$FAKE/editor-script"
mark
k Escape; lit e
check "e: bw unlock through pinentry, then the editor runs on invalid JSON first" wait_for 'Cannot save: not valid JSON' 10
lit e; k Enter
check "  'e' edits again; valid JSON is saved (Saved + rbw synced)" wait_for 'Saved' 10
check "  vault.json: new name, user and folder MCP" bash -c '[ "$(jq -r ".items[]|select(.id==\"i-github\")|[.name,.login.username,.folderId]|join(\"|\")" "$1/vault.json")" = "github.com edited|brizz2|f-mcp" ]' _ "$FAKE"
check "  the helper key _folder is not sent to bw" bash -c '! jq -e "has(\"_folder\")" "$1/last-edit.json" >/dev/null' _ "$FAKE"
check "  edit file: mode 600 in a 700 dir, shredded afterwards" bash -c 'grep -q "file 600 dir 700" "$1/editor.log" && ! ls "$2"/vault/edit/*.json 2>/dev/null | grep -q .' _ "$FAKE" "$RUN"
check "  rbw sync after the bw edit, bw edit argv has no item content" bash -c 'argv=$(tail -n +$(($2 + 1)) "$1/argv.log"); grep -q "^bw edit item i-github" <<<"$argv" && ! grep -qE "brizz2|PW-" <<<"$argv" && grep -q "^rbw sync" <<<"$argv"' _ "$FAKE" "$ARGV_MARK"
check "  the list shows the new name afterwards" wait_for 'github.com edited' 8
quit_menu
reset
start
lit github; sleep 0.5
printf '%s\n' 'BAD' >"$FAKE/editor-script"
k Escape; lit e
wait_for 'Cannot save' 10 >/dev/null
lit x; k Enter
check "invalid JSON then discard: nothing saved" bash -c 'wait=0; sleep 1.5; [ "$(jq -r ".items[]|select(.id==\"i-github\")|.name" "$1/vault.json")" = github.com ] && [ ! -e "$1/last-edit.json" ]' _ "$FAKE"
quit_menu
reset
start
lit github; sleep 0.5
printf '%s\n' '.id = "i-other"' 'NOP' >"$FAKE/editor-script"
k Escape; lit e
check "changing the id is refused" wait_for 'the id must not change' 10
lit x; k Enter; sleep 1.2; quit_menu
}

# 6. new items
s6() {
reset unlocked
start
k Tab Tab Tab
sleep 1
lit n >/dev/null
k Escape; lit n
check "n: type picker" wait_for 'New item: pick the type'
k Enter
check "  login: prompts for name, user, URI" wait_for 'Name:' 8
lit newsite; k Enter; lit bob; k Enter; lit https://new.example; k Enter; k Enter
check "  login created in the folder that was open (Work), generated password copied" bash -c 'sleep 2; [ "$(jq -r ".items[]|select(.name==\"newsite\")|[.folderId,.login.username,.login.password,.login.uris[0].uri]|join(\"|\")" "$1/vault.json")" = "f-work|bob|GEN-erated-Pw-0001|https://new.example" ] && [ "$(cat "$1/clip.txt")" = GEN-erated-Pw-0001 ]' _ "$FAKE"
check "  rbw synced, new login in the list" wait_for 'newsite' 8
quit_menu
reset unlocked
start
printf '%s\n' '.name = "Amex" | .card.number = "378282246310005" | .card.code = "9999"' >"$FAKE/editor-script"
k Escape; lit n; wait_for 'pick the type' >/dev/null; lit card; k Enter
check "new card from the bw template" bash -c 'sleep 2.5; [ "$(jq -r ".items[]|select(.name==\"Amex\")|[.type,.card.number,(.folderId // \"none\")]|join(\"|\")" "$1/vault.json")" = "3|378282246310005|none" ]' _ "$FAKE"
quit_menu
reset unlocked
start
printf '%s\n' '.name = "Server key" | .notes = "x"' >"$FAKE/editor-script"
k Escape; lit n; wait_for 'pick the type' >/dev/null; lit SSH; k Enter
check "new SSH key (no template in this bw: built-in fallback)" bash -c 'sleep 2.5; [ "$(jq -r ".items[]|select(.name==\"Server key\")|[.type,(.sshKey|has(\"privateKey\"))]|join(\"|\")" "$1/vault.json")" = "5|true" ]' _ "$FAKE"
quit_menu
}

# 7. delete -> trash, restore, delete for good
s7() {
reset unlocked
start
lit google; sleep 0.5
mark
k Escape; lit d
check "d: confirmation (no is the default)" wait_for 'Move "google.com" to the trash'
k Escape Escape
check "  cancelled: nothing deleted" bash -c 'sleep 1; ! tail -n +$(($2 + 1)) "$1/argv.log" | grep -q "^bw delete"' _ "$FAKE" "$ARGV_MARK"
quit_menu
reset unlocked
start
lit google; sleep 0.5
k Escape; lit d; wait_for 'Move "google.com"' >/dev/null
lit yes; k Enter
check "  confirmed: item moved to the trash, rbw synced" bash -c 'sleep 2; [ "$(jq -r ".items[]|select(.id==\"i-google\")|.deletedDate" "$1/vault.json")" != null ] && tail -n +$(($2 + 1)) "$1/argv.log" | grep -q "^rbw sync"' _ "$FAKE" "$ARGV_MARK"
check "  gone from the list (11 -> 10)" wait_for '10/10' 8
k Tab Tab Tab Tab Tab
check "  Trash view lists google.com and old-forum" bash -c 's=$1; grep -q google.com <<<"$s" && grep -q old-forum <<<"$s"' _ "$(sleep 1.5; screen)"
lit old-forum; sleep 0.5; k Escape; lit y
check "  y in the Trash: refused with a hint" wait_for 'in the trash' 3
k Escape Escape
quit_menu
reset unlocked
start
k Tab Tab Tab Tab Tab; sleep 1.5
lit old-forum; sleep 0.4
k Escape; lit r
check "r in the Trash: restored" bash -c 'sleep 2.5; [ "$(jq -r ".items[]|select(.id==\"i-old\")|.deletedDate" "$1/vault.json")" = null ]' _ "$FAKE"
quit_menu
reset unlocked
start
k Tab Tab Tab Tab Tab; sleep 1.5
lit old-forum; sleep 0.4
k Escape; lit d; wait_for 'for good' >/dev/null
lit yes; k Enter
check "d in the Trash: deleted for good after a confirmation" bash -c 'sleep 2.5; [ "$(jq -r "[.items[]|select(.id==\"i-old\")]|length" "$1/vault.json")" = 0 ] && grep -q -- "--permanent" "$1/argv.log"' _ "$FAKE"
quit_menu
}

# 8. attachments
s8() {
reset unlocked
start
lit docs; sleep 1
check "preview lists the attachment when bw is open" screen_has 'report.pdf \(11 Bytes\)'
k Escape; lit F
check "F: attachment picker" wait_for 'report.pdf' 8
lit report; sleep 0.3; k Enter
check "  download into BW_DOWNLOAD_DIR (never overwrites)" bash -c 'sleep 2; [ "$(cat "$1/dl/report.pdf")" = ATTACHMENT-CONTENT ]' _ "$FAKE"
quit_menu
reset unlocked
start
echo "upload me" >"$FAKE/up.txt"
lit github; sleep 0.5; k M-a
check "Alt+a: picker with the upload row" wait_for 'Upload a file'
k Enter
check "  file picker" wait_for 'upload>' 10
lit "$FAKE/up.txt"; sleep 0.5; k Enter
check "  uploaded as an attachment of the item" bash -c 'sleep 2.5; [ "$(cat "$1/last-upload")" = "upload me" ] && [ "$(jq -r ".items[]|select(.id==\"i-github\")|.attachments[0].fileName" "$1/vault.json")" = up.txt ]' _ "$FAKE"
quit_menu
}

# 9. history, generator, send
s9() {
reset
start
lit github; sleep 0.5; k Escape; lit h
check "h: history picker shows masked passwords only" bash -c 's=$1; grep -q "2026-01-01" <<<"$s" && grep -q "\*\*\*\*" <<<"$s"' _ "$(sleep 1; screen)"
k Enter
check "  Enter copies the old password (sensitive)" bash -c 'sleep 1; [ "$(cat "$1/clip.txt")" = OLDPASS-1 ] && grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
reset
start
k M-w
check "Alt+w: generator presets" wait_for 'Password, 20 characters' 10
k Enter
check "  generated password copied sensitive" bash -c 'sleep 1.5; [ "$(cat "$1/clip.txt")" = GEN-erated-Pw-0001 ] && grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
quit_menu
reset unlocked
start
k Escape; lit S
check "S: Send picker" wait_for 'what to share'
k Enter
check "  Send text prompts" wait_for 'Text to send' 10
lit hello; k Enter Enter
sleep 0.5; k Enter Enter Enter Enter
check "  Send created, link copied as plain text" bash -c 'sleep 2; [ "$(cat "$1/clip.txt")" = "https://send.example/#/abc/def" ] && ! grep -q -- --sensitive "$1/clip.args"' _ "$FAKE"
quit_menu
}

# 10. sync, unlock, lock, app
s10() {
reset unlocked
start
mark
k M-s
check "Alt+s: rbw sync and bw sync" bash -c 'sleep 2; a=$(tail -n +$(($2 + 1)) "$1/argv.log"); grep -q "^rbw sync" <<<"$a" && grep -q "^bw sync" <<<"$a"' _ "$FAKE" "$ARGV_MARK"
check "  the browser stays open" screen_has 'Folder: All'
mark
k M-l
check "Alt+l: locks rbw and bw, drops the session, exits" bash -c 'sleep 2; [ -f "$1/rbw-locked" ] && [ ! -f "$1/bw-unlocked" ] && [ ! -e "$2/vault/bw-session" ]' _ "$FAKE" "$RUN"
check "  browser exited after the lock" wait_for 'EXIT\[0\]' 5
reset
start
k Escape; lit b
check "b: unlock bw through pinentry" bash -c 'sleep 2.5; [ -f "$1/bw-unlocked" ] && [ -s "$2/vault/bw-session" ]' _ "$FAKE" "$RUN"
check "  header no longer shows the bw hint" wait_gone 'bw locked' 
quit_menu
reset
start
k Escape; lit O
check "O: opens the desktop app and exits" bash -c 'sleep 1.5; [ -s "$1/app.log" ]' _ "$FAKE"
reset
start
k Escape; lit G; sleep 0.5; k Enter
check "Enter on the hint row opens the app" bash -c 'sleep 1.5; [ -s "$1/app.log" ]' _ "$FAKE"
}

# 11. edge cases: no match, no selection
s11() {
reset
start
lit zzzzzz; sleep 0.5
k Escape; lit y
check "y with no match: hint, browser keeps running" bash -c 'sleep 1; grep -q "No item selected" "$1/notify.log"' _ "$FAKE"
check "  the list is still there" screen_has 'vault>'
k Escape Escape
sleep 0.5
reset
start
lit zzzzzz; sleep 0.5
k M-n
check "Alt+n with no match still opens the new-item picker" wait_for 'pick the type' 6
k Escape Escape; sleep 0.5
}

# 12. startup folder argument and a locked vault
s12() {
reset
start Linux
check "vault-browse Linux starts in that folder" bash -c 's=$1; grep -q "Folder: Linux (2/6)" <<<"$s" && grep -q skalse <<<"$s" && ! grep -q github.com <<<"$s"' _ "$(sleep 1; screen)"
quit_menu
reset
touch "$FAKE/rbw-locked"
start
check "locked rbw (cancelled unlock): notification, exit 1" bash -c 'sleep 2; grep -q "Could not read the vault" "$1/notify.log"' _ "$FAKE"
}

# 13. no tty (how the Hyprland bind runs it): the list opens through fzf-menu's terminal, steps with a keyboard in their own
s13() {
  reset
  startgui
  check "no tty: the menu opens in a terminal window (fzf-menu cold path)" screen_has 'Folder: All \(1/6\)'
  check "  float.tui terminal started by fzf-menu" file_has "$FAKE/gui.log" 'class=float.tui.*serve-request'
  lit github; sleep 0.6
  k Tab
  check "  Tab in the terminal window reloads the folder" screen_has 'Folder: Linux \(2/6\)'
  k Escape; lit c; k BTab; sleep 0.8
  lit github; sleep 0.6; k Escape; lit y
  check "  y copies and the browser ends" bash -c 'sleep 1.5; [ "$(cat "$1/clip.txt")" = "PW-github-s3cret!" ]' _ "$FAKE"
  check "  exit code 0 after the menu windows closed" wait_for 'EXIT\[0\]' 6
  reset
  startgui
  printf '%s\n' '.name = "github.com via window" | .login.username = "viewin"' >"$FAKE/editor-script"
  lit github; sleep 0.6; k Escape; lit e
  check "  e: the editor step opens its own terminal window (_act) and saves" bash -c 'for i in $(seq 40); do [ -f "$1/last-edit.json" ] && exit 0; sleep 0.3; done; exit 1' _ "$FAKE"
  check "  _act was started through VAULT_TERMINAL with the item id" file_has "$FAKE/gui.log" '_act edit i-github'
  check "  the list comes back with the new name" wait_for 'github.com via window' 12
  check "  secret never reached the argv of the terminal commands" bash -c '! grep -qE "PW-|brizzinck|TOKEN-api" "$1/gui.log"' _ "$FAKE"
  quit_menu
}

# ONLY=3,5 runs those sections only (default: all)
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  [[ -z ${ONLY:-} || ,$ONLY, == *",$n,"* ]] && "s$n"
done

# ───────────── secrets: screen, argv, process list ─────────────
kill "$SAMPLER" 2>/dev/null; SAMPLER=""
leaks=0
for s in "${SECRETS[@]}"; do
  if grep -aqF -- "$s" "$FAKE/argv.log"; then echo "LEAK in argv: $s"; leaks=1; fi
  if grep -aqF -- "$s" "$FAKE/ps.log"; then echo "LEAK in the process list: $s"; leaks=1; fi
done
check "no secret in the argv of any fake tool (rbw, bw, wl-copy, wtype, notify-send)" test "$leaks" = 0
check "no secret in ps output sampled every 50 ms during the whole run" test "$leaks" = 0
check "no secret on the screen in ${#SECRETS[@]} secrets x every captured frame" test ! -s "$FAKE/leaks.log"
[[ -s $FAKE/leaks.log ]] && sort -u "$FAKE/leaks.log"
check "no secret in any notification" bash -c '! grep -qE "PW-|TOKEN-api|4111111111111111|CVV-|SSN-|PASSPORT-AB|NOTE-secret|SSHPRIVATE|OLDPASS" "$1/notify.log" 2>/dev/null' _ "$FAKE"

printf '\nvault-browse test: %d passed, %d failed\n' "$PASS" "$FAILS"
((FAILS == 0))
