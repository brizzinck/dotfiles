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

REAL_XDG=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/vault-browse-test.XXXXXX")
RUN="$FAKE/run"
SOCK="vbtest-$$"
T=(tmux -L "$SOCK")
export FAKE_DIR="$FAKE"
PASS=0 FAILS=0
SECRETS=('PW-github-s3cret!' 'TOKEN-api-hidden-777' '4111111111111111' 'CVV-secret-737' 'SSN-123-45-6789' 'PASSPORT-AB123456'
  'NOTE-secret-text' 'SSHPRIVATE-zzz' 'LINUXPASS-skalse-1' 'OLDPASS-1' 'master-pw' 'JBSWY3DPEHPK3PXP' 'PW-gitlab-pass'
  'PW-google-pass' 'PW-docs-pass' 'PW-old-forum' 'PW-tg-mcp-pass' 'LINUXPASS-new-2' 'LINUXPASS-new-3')

cleanup() {
  "${T[@]}" kill-server 2>/dev/null
  stop_bw_servers
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
export VAULT_BW_LAUNCH=popen VAULT_BW_SERVE_POLL=0.3
unset TG_SKIP TMUX_PANE
ENV
echo '{"email":"test@example.com"}' >"$FAKE/rbw.json"

stop_bw_servers() { # the per-session bw server of the previous case (found by its pid file) and its fake bw child
  local pid
  pid=$(cat "$RUN/vault/bw-serve.pid" 2>/dev/null)
  if [[ -n $pid ]] && grep -aq 'vault-bw.py' "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  fi
}

reset() { # [unlocked]: fresh vault and logs; "unlocked" starts with an open bw session
  "${T[@]}" kill-server 2>/dev/null
  stop_bw_servers
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

# BW1: the per-session bw server (vault-bw.py) and the rbw-first call sites, offline (fake rbw, fake bw, fake bw serve)
bw_count() { grep -ac "^$1" "$FAKE/argv.log" 2>/dev/null || true; }   # "bw " = CLI processes, "bw-serve " = requests
srv_pid() { cat "$RUN/vault/bw-serve.pid" 2>/dev/null; }
srv_alive() { local p; p=$(srv_pid); [[ -n $p ]] && grep -aq '_serve' "/proc/$p/cmdline" 2>/dev/null; }
wait_srv_gone() { local i; for ((i = 0; i < ${1:-40}; i++)); do ! srv_alive && [[ ! -S $RUN/vault/bw.sock ]] && return 0; sleep 0.2; done; return 1; }
quick_bw1() {
  local V="$SCRIPTS/vault-bw.py" out p1 p2 key=SESSION-KEY-abc
  reset unlocked
  # shellcheck disable=SC1091
  . "$FAKE/env.sh"
  : >"$FAKE/argv.log"
  out=$(python3 -I "$V" call list folders </dev/null)
  check "server: the first bw action starts ONE bw serve, then it is requests only" bash -c 'a=$(grep -a "^bw " "$1/argv.log"); [ "$(wc -l <<<"$a")" = 1 ] && grep -q "^bw serve --hostname unix://" <<<"$a" && grep -q "^bw-serve GET /list/object/folders" "$1/argv.log"' _ "$FAKE"
  check "server: answer has the CLI shape (a JSON array of folders)" bash -c 'jq -e "type==\"array\" and (map(.name) | index(\"Work\"))" <<<"$1" >/dev/null' _ "$out"
  python3 -I "$V" call get item i-github </dev/null >/dev/null
  python3 -I "$V" call list items --trash </dev/null >/dev/null
  check "server: later calls start no process" bash -c '[ "$(grep -ac "^bw " "$1/argv.log")" = 1 ] && grep -aq "^bw-serve GET /object/item/i-github" "$1/argv.log" && grep -aq "^bw-serve GET /list/object/items?trash=true" "$1/argv.log"' _ "$FAKE"
  check "socket: mode 600 (an umask-077 process), directory 700, owned by the owner" bash -c '[ "$(stat -c %a "$1/bw.sock")" = 600 ] && [ "$(stat -c %a "$1")" = 700 ] && [ "$(stat -c %U "$1/bw.sock")" = "$(id -un)" ]' _ "$RUN/vault"
  check "socket: no TCP listener of the server (port 8087, any bw process)" bash -c '! ss -ltnpH 2>/dev/null | grep -Eq "\"bw\"|bw-serve|[:.]8087[[:space:]]"'
  check "socket: nobody (another user) cannot reach it (acl-reach.py)" bash -c 'out=$(python3 -I "$1/infrastructure/users/acl-reach.py" "$(id -u nobody)" "$2" 2>&1); ! grep -q "bw.sock" <<<"$out"' _ "$REPO" "$RUN"
  p1=$(srv_pid)
  check "secret: the session key is in no argv (supervisor, bw child, argv log, start command)" bash -c 'for p in $(pgrep -f "^(/usr/bin/)?python3 .*(vault-bw.py _serve|bw-serve.py)"); do tr "\0" " " </proc/$p/cmdline | grep -q "$2" && exit 1; done; ! grep -aq "$2" "$1/argv.log"; exit 0' _ "$FAKE" "$key"
  check "secret: the key reaches the bw child through its environment only; the log is 600 and holds no key" bash -c 'c=$(pgrep -P "$1" | head -1); tr "\0" "\n" </proc/$c/environ | grep -q "^BW_SESSION=$3$" && [ "$(stat -c %a "$2/bw-serve.log")" = 600 ] && ! grep -aq "$3" "$2/bw-serve.log"' _ "$p1" "$RUN/vault" "$key"
  # write paths through the server: create / edit / delete / restore / attachment
  : >"$FAKE/argv.log"
  jq -nc '{type:1,name:"viaserver",notes:null,favorite:false,folderId:null,fields:[],login:{username:"u",password:"PW-gitlab-pass",totp:null,uris:[]}}' | base64 -w0 | python3 -I "$V" call --stdin create item >/dev/null
  check "server: create item (body is the base64 JSON from stdin) reaches the vault, not argv" bash -c '[ "$(jq -r ".items[]|select(.name==\"viaserver\")|.login.username" "$1/vault.json")" = u ] && ! grep -aq "PW-gitlab" "$1/argv.log" && grep -aqx "bw-serve POST /object/item" "$1/argv.log"' _ "$FAKE"
  python3 -I "$V" call delete item i-google </dev/null; python3 -I "$V" call restore item i-google </dev/null >/dev/null; python3 -I "$V" call delete item i-wifi --permanent </dev/null
  check "server: delete (trash) / restore / delete --permanent map to DELETE, POST restore, DELETE ?permanent" bash -c 'grep -aq "^bw-serve DELETE /object/item/i-google$" "$1/argv.log" && grep -aq "^bw-serve POST /restore/item/i-google" "$1/argv.log" && grep -aq "^bw-serve DELETE /object/item/i-wifi?permanent=true" "$1/argv.log" && [ "$(jq -r "[.items[]|select(.id==\"i-wifi\")]|length" "$1/vault.json")" = 0 ] && [ "$(jq -r ".items[]|select(.id==\"i-google\")|.deletedDate" "$1/vault.json")" = null ]' _ "$FAKE"
  echo "upload me" >"$FAKE/up2.txt"
  python3 -I "$V" call create attachment --file "$FAKE/up2.txt" --itemid i-github </dev/null >/dev/null
  python3 -I "$V" call get attachment att-1 --itemid i-github --output "$FAKE/dl/got.bin" </dev/null >/dev/null
  check "server: attachment upload (multipart) and download (to a 600 file)" bash -c '[ "$(cat "$1/last-upload")" = "upload me" ] && [ "$(cat "$1/dl/got.bin")" = ATTACHMENT-CONTENT ] && [ "$(stat -c %a "$1/dl/got.bin")" = 600 ]' _ "$FAKE"
  check "server: an error answer keeps the CLI behaviour (exit 1, message on stderr)" bash -c 'out=$(python3 -I "$1" call get item i-nothing </dev/null 2>&1); rc=$?; [ $rc = 1 ] && grep -q "Not found" <<<"$out"' _ "$V"
  check "no REST form (Send create) falls back to the CLI process" bash -c ': >"$1/argv.log"; echo "{}" | base64 -w0 | python3 -I "$2" call --stdin send create >/dev/null 2>&1; grep -aq "^bw send create" "$1/argv.log"' _ "$FAKE" "$V"
  # lock stops the server, drops the session
  python3 -I "$V" lock </dev/null
  check "lock: server stopped, socket gone, session dropped, bw locked" bash -c '! kill -0 "$1" 2>/dev/null && [ ! -e "$2/bw.sock" ] && [ ! -e "$2/bw-session" ] && [ ! -f "$3/bw-unlocked" ]' _ "$p1" "$RUN/vault" "$FAKE"
  # CLI-only mode and fallback when the server cannot start
  reset unlocked
  : >"$FAKE/argv.log"
  VAULT_BW_SERVE=0 python3 -I "$V" call list folders </dev/null >/dev/null
  check "fallback: VAULT_BW_SERVE=0 uses the bw process and starts no server" bash -c 'grep -aq "^bw list folders" "$1/argv.log" && ! grep -aq "^bw serve" "$1/argv.log" && [ ! -S "$2/bw.sock" ]' _ "$FAKE" "$RUN/vault"
  : >"$FAKE/argv.log"
  printf '#!/bin/sh\n[ "$1" = serve ] && exit 3\nexec %s "$@"\n' "$BIN/bw" >"$FAKE/badbw"; chmod +x "$FAKE/badbw"
  out=$(BW_BIN="$FAKE/badbw" VAULT_BW_SERVE_POLL=0.2 python3 -I "$V" call list folders </dev/null)
  check "fallback: a server that cannot start falls back to the CLI, same answer" bash -c 'jq -e "type==\"array\"" <<<"$1" >/dev/null && ! grep -aq "^bw-serve" "$2/argv.log"' _ "$out" "$FAKE"
    # a server killed hard leaves a stale socket: the next call starts a new one
  reset unlocked
  python3 -I "$V" call list folders </dev/null >/dev/null
  p1=$(srv_pid); kill -9 "$p1"; sleep 0.5
  : >"$FAKE/argv.log"
  out=$(python3 -I "$V" call list folders </dev/null)
  p2=$(srv_pid)
  check "stale socket after a kill -9: the next call replaces the server and works" bash -c 'jq -e "type==\"array\"" <<<"$1" >/dev/null && [ -n "$3" ] && [ "$3" != "$2" ]' _ "$out" "$p1" "$p2"
  # session-start (login) stops a server left over by a lingering user manager
  reset unlocked
  python3 -I "$V" call list folders </dev/null >/dev/null
  p1=$(srv_pid)
  "$VAULT_SH" session-start >/dev/null 2>&1
  check "session-start: the old server is stopped and the old session dropped" bash -c 'for i in $(seq 40); do kill -0 "$1" 2>/dev/null || exit 0; sleep 0.2; done; exit 1' _ "$p1"
  check "  no socket, no session file left" bash -c '[ ! -e "$1/bw.sock" ] && [ ! -e "$1/bw-session" ]' _ "$RUN/vault"
  # unlock starts the server with the NEW key and syncs through it
  reset
  : >"$FAKE/argv.log"
  python3 -I "$V" unlock </dev/null >/dev/null
  check "unlock: pinentry -> one bw unlock process -> server started -> sync is a request" bash -c 'grep -aqx "bw unlock --raw --passwordenv BWV_MP" "$1/argv.log" && grep -aq "^bw serve" "$1/argv.log" && grep -aq "^bw-serve POST /sync" "$1/argv.log" && ! grep -aq "^bw sync" "$1/argv.log"' _ "$FAKE"
  check "  a second ensure() costs no process at all" bash -c 'n=$(grep -ac "^bw " "$1/argv.log"); python3 -I "$2" unlock </dev/null; [ "$(grep -ac "^bw " "$1/argv.log")" = "$n" ]' _ "$FAKE" "$V"
  python3 -I "$V" lock </dev/null
  # rbw-first call sites
  reset unlocked
  : >"$FAKE/argv.log"
  out=$("$REPO/.local/bin/linux-pass" --list </dev/null 2>&1)
  check "linux-pass --list: names come from rbw, bw is not started at all" bash -c '! grep -aqE "^bw( |-serve)" "$1/argv.log" && grep -aq "^rbw list --raw" "$1/argv.log" && grep -q "skalse" <<<"$2"' _ "$FAKE" "$out"
  check "generator: character passwords are made locally (no bw process), 24 chars with every class" bash -c 'python3 -I - "$1" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vb", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
pw = m.generate_password("-ulns", "--length", "24")
assert len(pw) == 24 and any(c.isupper() for c in pw) and any(c.islower() for c in pw) and any(c.isdigit() for c in pw) and any(c in "!@#$%^&*" for c in pw), pw
pw = m.generate_password("-uln", "--length", "20")
assert len(pw) == 20 and pw.isalnum()
PY' _ "$V"
  check "  and no bw process was needed for it" bash -c '! grep -aq "^bw generate" "$1/argv.log"' _ "$FAKE"
  stop_bw_servers
  quick_linux_pass_unreadable
}

# BW1-fix 1: a folder that cannot be read is not an empty folder (linux-pass used to create duplicates). The command needs a
# terminal, so it runs under script(1) with blank lines on stdin (Enter = skip every password).
lp_run() { # ARGS...: prints the transcript, last line LP_RC=<exit status of linux-pass>
  yes '' | head -30 | script -qec "$REPO/.local/bin/linux-pass $*; echo LP_RC=\$?" /dev/null 2>&1 | tr -d '\r'
}
quick_linux_pass_unreadable() {
  local out
  command -v script >/dev/null || { printf 'skip  linux-pass unreadable folder (no script(1))\n'; return; }
  reset unlocked
  touch "$FAKE/rbw-locked"
  : >"$FAKE/argv.log"
  out=$(lp_run)
  check "linux-pass setup, rbw locked: the folder is read through bw, the stored user is not asked again" bash -c 'grep -q "skalse: already stored, skipped" <<<"$1" && ! grep -q "Linux password of skalse" <<<"$1" && grep -aq "^bw-serve GET /list/object/items" "$2/argv.log"' _ "$out" "$FAKE"
  check "  no item was created or edited" bash -c '! grep -aqE "^bw-serve (POST /object/item|PUT)" "$1/argv.log"' _ "$FAKE"
  stop_bw_servers
  # rbw AND bw unreadable: stop before asking anything, create nothing
  reset unlocked
  touch "$FAKE/rbw-locked"
  printf 'import sys\na = sys.argv[1:]\nif a[:1] == ["state"]:\n    print("unlocked"); sys.exit(0)\nsys.exit(0 if a[:2] == ["call", "sync"] else 1)   # bw answers sync, nothing else\n' >"$FAKE/badvault.py"
  : >"$FAKE/argv.log"
  out=$(VAULT_BW="$FAKE/badvault.py" lp_run)
  check "linux-pass setup, rbw and bw both failing: stops, asks no password, creates nothing" bash -c '! grep -q "Linux password of" <<<"$1" && grep -qE "bw list folders failed|could not read the folder" <<<"$1" && ! grep -q "LP_RC=0" <<<"$1"' _ "$out"
  out=$(VAULT_BW="$FAKE/badvault.py" lp_run --update skalse)
  check "linux-pass --update, rbw and bw both failing: no new item for an existing user" bash -c '! grep -q "no item yet, created" <<<"$1" && ! grep -q "LP_RC=0" <<<"$1"' _ "$out"
  stop_bw_servers
}

# the slow BW1 cases (idle limit, rbw lock): full run only
quick_bw1_slow() {
  local V="$SCRIPTS/vault-bw.py" p1 p2
  # shellcheck disable=SC1091
  . "$FAKE/env.sh"
  # idle stop: the key stays, the next action starts it again
  reset unlocked
  VAULT_BW_IDLE=2 python3 -I "$V" call list folders </dev/null >/dev/null
  p1=$(srv_pid)
  check "idle: the server stops after the idle limit (VAULT_BW_IDLE)" wait_srv_gone 50
  check "idle: socket removed, the session file stays" bash -c '[ ! -e "$1/bw.sock" ] && [ -s "$1/bw-session" ]' _ "$RUN/vault"
  VAULT_BW_IDLE=600 python3 -I "$V" call list folders </dev/null >/dev/null
  p2=$(srv_pid)
  check "idle: the next bw action starts a new server with the stored key" bash -c '[ -n "$2" ] && [ "$1" != "$2" ] && kill -0 "$2"' _ "$p1" "$p2"
  # rbw lock stops it (the agent was seen unlocked first)
  sleep 0.8
  touch "$FAKE/rbw-locked"
  check "rbw lock: the server stops (and the session key stays for a later start)" wait_srv_gone 30
  stop_bw_servers
  # the real launch path: a transient user unit of the user manager (own unit name, own runtime dir; skipped without a manager)
  if XDG_RUNTIME_DIR=$REAL_XDG systemctl --user show-environment >/dev/null 2>&1 && command -v systemd-run >/dev/null; then
    local unit="vault-bw-serve-test-$$" sd="env XDG_RUNTIME_DIR=$REAL_XDG systemctl --user"
    reset unlocked
    VAULT_BW_LAUNCH=auto VAULT_BW_UNIT=$unit VAULT_BW_SYSTEMD_RUNTIME=$REAL_XDG python3 -I "$V" call list folders </dev/null >/dev/null
    check "unit launch: the server runs as a transient user unit (outlives the window it was started from)" bash -c '$1 is-active '$unit' | grep -qx active' _ "$sd"
    check "  the session key is not a property of the unit (it is read from the 600 file)" bash -c '! $1 show '$unit' -p Environment | grep -q SESSION-KEY' _ "$sd"
    VAULT_BW_LAUNCH=auto VAULT_BW_UNIT=$unit VAULT_BW_SYSTEMD_RUNTIME=$REAL_XDG python3 -I "$V" lock </dev/null
    check "  lock ends the unit" bash -c 'sleep 1; ! $1 is-active '$unit' | grep -qx active' _ "$sd"
    $sd stop "$unit" 2>/dev/null
  else
    printf 'skip  unit launch (no user manager)\n'
  fi
}

quick

quick_bw1

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
check "  rbw sync after the bw edit, bw edit argv has no item content" bash -c 'argv=$(tail -n +$(($2 + 1)) "$1/argv.log"); grep -qE "^(bw edit item i-github|bw-serve PUT /object/item/i-github)" <<<"$argv" && ! grep -qE "brizz2|PW-" <<<"$argv" && grep -q "^rbw sync" <<<"$argv"' _ "$FAKE" "$ARGV_MARK"
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
check "  login created in the folder that was open (Work), generated password copied" bash -c 'sleep 2; [ "$(jq -r ".items[]|select(.name==\"newsite\")|[.folderId,.login.username,.login.password,.login.uris[0].uri]|join(\"|\")" "$1/vault.json")" = "f-work|bob|$(cat "$1/clip.txt")|https://new.example" ] && grep -qE "^[A-Za-z0-9]{24}$" "$1/clip.txt"' _ "$FAKE"
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
check "d in the Trash: deleted for good after a confirmation" bash -c 'sleep 2.5; [ "$(jq -r "[.items[]|select(.id==\"i-old\")]|length" "$1/vault.json")" = 0 ] && grep -qE -- "--permanent|permanent=true" "$1/argv.log"' _ "$FAKE"
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
check "  generated password (20 letters and digits, made without a bw process) copied sensitive" bash -c 'sleep 1.5; grep -qE "^[A-Za-z0-9]{20}$" "$1/clip.txt" && grep -q -- --sensitive "$1/clip.args" && ! grep -aq "^bw generate" "$1/argv.log"' _ "$FAKE"
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
check "Alt+s: rbw sync and bw sync" bash -c 'sleep 2; a=$(tail -n +$(($2 + 1)) "$1/argv.log"); grep -q "^rbw sync" <<<"$a" && grep -qE "^(bw sync|bw-serve POST /sync)" <<<"$a"' _ "$FAKE" "$ARGV_MARK"
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

[[ -z ${ONLY:-} || ,$ONLY, == *",14,"* ]] && quick_bw1_slow

# 15. linux-pass (BW1): reads through rbw, writes through the bw server; passwords only in the terminal and the item body
s15() {
  reset unlocked
  mark
  "${T[@]}" new-session -d -s t -x 150 -y 42 "bash --noprofile --norc -c '. $FAKE/env.sh; $REPO/.local/bin/linux-pass --update skalse; echo EXIT[\$?]; sleep 30'"
  check "linux-pass --update: asks for the password on the terminal" wait_for 'Linux password of skalse' 15
  lit 'LINUXPASS-new-2'; k Enter
  check "  asks again to confirm" wait_for 'Again to confirm' 5
  lit 'LINUXPASS-new-2'; k Enter
  check "  finishes: password replaced" wait_for 'skalse: password replaced' 20
  check "  the item in the vault has the new password, name and folder unchanged" bash -c 'wait=0; sleep 0.5; [ "$(jq -r ".items[]|select(.id==\"i-skalse\")|[.login.password,.name,.folderId]|join(\"|\")" "$1/vault.json")" = "LINUXPASS-new-2|skalse|f-linux" ]' _ "$FAKE"
  check "  bw ran as ONE process (the server); everything else was a request, and rbw gave the list" bash -c 'a=$(tail -n +$(($2 + 1)) "$1/argv.log"); [ "$(grep -ac "^bw " <<<"$a")" = 1 ] && grep -aq "^bw serve" <<<"$a" && grep -aq "^bw-serve PUT /object/item/i-skalse" <<<"$a" && grep -aq "^rbw list --raw" <<<"$a" && ! grep -aq "LINUXPASS" <<<"$a"' _ "$FAKE" "$ARGV_MARK"
  wait_for 'EXIT\[0\]' 10 >/dev/null
  check "  bw was already open, so it stays open (nothing to lock again)" bash -c '[ -s "$1/vault/bw-session" ]' _ "$RUN"
  reset unlocked
  "${T[@]}" new-session -d -s t -x 150 -y 42 "bash --noprofile --norc -c '. $FAKE/env.sh; $REPO/.local/bin/linux-pass --update newuser; echo EXIT[\$?]; sleep 30'"
  wait_for 'Linux password of newuser' 15 >/dev/null
  lit 'LINUXPASS-new-3'; k Enter; wait_for 'Again to confirm' 5 >/dev/null; lit 'LINUXPASS-new-3'; k Enter
  check "linux-pass --update of an unknown user creates the item in the folder" bash -c 'for i in $(seq 40); do [ "$(jq -r ".items[]|select(.name==\"newuser\")|[.login.username,.login.password,.folderId]|join(\"|\")" "$1/vault.json")" = "newuser|LINUXPASS-new-3|f-linux" ] && exit 0; sleep 0.3; done; exit 1' _ "$FAKE"
  wait_for 'EXIT\[0\]' 10 >/dev/null
  # a locked bw: the unlock goes through pinentry, and linux-pass locks it again at the end (it opened it)
  reset
  "${T[@]}" new-session -d -s t -x 150 -y 42 "bash --noprofile --norc -c '. $FAKE/env.sh; export WAYLAND_DISPLAY=fake-wl; $REPO/.local/bin/linux-pass --update skalse; echo EXIT[\$?]; sleep 30'"
  wait_for 'Linux password of skalse' 20 >/dev/null
  lit 'LINUXPASS-new-2'; k Enter; wait_for 'Again to confirm' 5 >/dev/null; lit 'LINUXPASS-new-2'; k Enter
  check "linux-pass with a locked bw: pinentry unlock, then it locks bw and stops the server again" wait_for 'bw locked again' 25
  wait_for 'EXIT\[0\]' 10 >/dev/null
  check "  session file gone, no server left" bash -c '[ ! -e "$1/vault/bw-session" ] && [ ! -S "$1/vault/bw.sock" ]' _ "$RUN"
}

# ONLY=3,5 runs those sections only (default: all)
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 15; do
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
