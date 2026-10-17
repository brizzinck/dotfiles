#!/usr/bin/env bash
# vault: Bitwarden / Vaultwarden front end on top of rbw + fzf-menu (vim keys).
# SUPER+CTRL+P (passwords), SUPER+CTRL+O (2FA codes), waybar custom/vault, hub rows.
#
#   vault.sh passwords          fzf-menu over `rbw list` (name, user, folder). Enter types user, Tab, password into the
#                               window that was focused before the menu (wtype, text on stdin: never in argv);
#                               Alt+p / NORMAL p types the password only, Alt+u / u the user only, Alt+c / y copies the
#                               password (sensitive, cleared in 30 s), Alt+t / t copies the TOTP code. The preview
#                               shows name, user, folder, URIs and whether a TOTP key exists, never a secret.
#   vault.sh totp               the logins that have a TOTP key: live code + seconds left in the preview (ticks every
#                               second); Enter / y copies the code (clears after 30 s), Alt+t / t types it,
#                               Alt+r / r rescans the vault
#   vault.sh totp-tui           same list in the current terminal (hub row)
#   vault.sh user-pass          SUPER+CTRL+U: type the Linux password of the user the focused window asks for (no Enter).
#                               Bitwarden folder `Linux`, one login per Linux user, item name = user name. The user comes
#                               from the window (vault-who.py: terminal foreground process through tmux, sudo -> the
#                               invoking user, su NAME -> NAME, polkit agent -> the owner). Typed only into terminals
#                               and the polkit agent; any other window gets a 30 s clipboard copy instead. An unknown
#                               user or a missing item opens an fzf-menu picker over the folder.
#   vault.sh browse [--here] [FOLDER]
#                               SUPER+CTRL+SHIFT+P: the vault browser (vault-browse.py). One modal list of every item (login,
#                               card, identity, note, SSH key) over rbw, Tab cycles the folders and the Trash, the preview
#                               masks every secret and ticks the TOTP code; letters / Alt keys copy, type, edit, create,
#                               trash, restore, attach, send, sync and lock (keys: header of vault-browse.py). rbw lists,
#                               previews, copies and types; bw (vault-bw.py) does Trash, attachments, edit, new, delete
#   vault.sh lock               lock the vault now: rbw lock and the official CLI session (bw lock; also stops the
#                               per-session `bw serve` on $XDG_RUNTIME_DIR/vault/bw.sock that vault-bw.py runs)
#   vault.sh sync               rbw sync (asks for the master password when locked) and, when its session is open, bw sync
#   vault.sh status             print locked|unlocked|unconfigured|missing, exit 0 only when unlocked
#   vault.sh waybar             JSON for the custom/vault module (signal 15)
#   vault.sh session-start      Hyprland exec-once: stop the rbw agent and drop the bw session (and its server) left over
#                               from the previous login so the master password is asked once per login session (silent without
#                               rbw/bw); starts the Bitwarden desktop app (tray, no focus) when the SSH agent is on
#   vault.sh bw CMD             official CLI actions (vault-bw.py): unlock new-login generate edit history send-text
#                               send-file attach-get attach-add delete (hub rows in actions.d/u6.tsv)
#   vault.sh app                open the Bitwarden desktop app (a running one shows its window)
#   vault.sh web                open the web vault (URL read from the rbw config at run time)
#   vault.sh ssh-agent on|off|toggle|status
#                               opt-in: use the desktop app's SSH agent in shells (flag in ~/.local/state/vault/)
#   vault.sh arm-clear          clear the clipboard in 30 s if it still holds the same sensitive value
#   --dry-run                   print what would run, change nothing
#
# `rbw unlocked` is the only state probe: it never starts the agent and never opens pinentry (checked on rbw 1.15).
# Secrets are copied with wl-copy --sensitive (cliphist skips them), never shown in notifications, never written to disk.
set -u

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
SELF="$HERE/vault.sh"
# shellcheck source=type-guard.sh
. "$HERE/type-guard.sh"
TYPE_PREV=''   # the window the menu was opened over: the only one text is typed into (type-guard.sh)
TOTP_PY="$HERE/vault-totp.py"
BW_PY="$HERE/vault-bw.py"
BROWSE_PY="$HERE/vault-browse.py"
WHO_PY="$HERE/vault-who.py"
LINUX_FOLDER=Linux
RUN="${XDG_RUNTIME_DIR:-/tmp}/vault"
BW_SESSION_FILE="$RUN/bw-session"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vault"
SSH_FLAG="$STATE_DIR/ssh-agent"
SSH_SOCK="${BITWARDEN_SSH_AUTH_SOCK:-$HOME/.bitwarden-ssh-agent.sock}"
RBW_CONF="${VAULT_RBW_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/rbw/config.json}"
G_LOCKED='󰌾'
G_OPEN='󰌿'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

have() { command -v "$1" >/dev/null 2>&1; }
note() { notify-send -a vault -u "${3:-low}" -t 4000 -h string:x-dunst-stack-tag:vault "$1" "${2:-}"; }
poke_bar() { pkill -o -u "$UID" -RTMIN+15 -x waybar 2>/dev/null || true; }
forget_index() { rm -f "$RUN/totp-index.tsv" "$RUN/totp-index.tmp" "$RUN/browse-index.json" "$RUN/browse-index.tmp"; }

configured() { [[ -s $RBW_CONF ]] && jq -e '.email != null' "$RBW_CONF" >/dev/null 2>&1; }

# the vault is ready to be used: rbw installed and configured; otherwise tell the owner what to do
need_ready() {
  if ! have rbw; then
    note "Vault" "rbw is not installed (sudo ./apply-system.sh --only install)" critical
    return 1
  fi
  if ! configured; then
    note "Vault is not set up" "Run bw-setup in a terminal first" critical
    return 1
  fi
}

state() {
  if ! have rbw; then echo missing; return 1; fi
  if ! configured; then echo unconfigured; return 1; fi
  if rbw unlocked >/dev/null 2>&1; then echo unlocked; return 0; fi
  echo locked
  return 1
}

arm_clear() { have wl-paste && python3 -I "$TOTP_PY" arm-clear 2>/dev/null; return 0; }

# the `become` NORMAL-mode spelling of a key that must leave the list like an --expect key
nb() { printf '%s:become(printf "%%s\\n%%s\\n" %s {})' "$1" "$2"; }

# preview of one login for the passwords list: metadata only, `rbw get --raw` output goes through jq and the
# password / totp secret / notes / hidden fields never reach stdout
pw_preview() {
  rbw get --raw "$1" 2>/dev/null | jq -r '
    "\(.name)\n",
    "user     \(.data.username // "-")",
    "folder   \(.folder // "-")",
    "totp     \(if .data.totp then "yes (Alt+t)" else "no" end)",
    "notes    \(if (.notes // "") != "" then "yes" else "no" end)",
    "",
    (.data.uris // [] | .[] | "uri      \(.uri)")' 2>/dev/null || echo "could not read the entry"
}

type_text() { # text on stdin -> the window recorded before the menu (stdin keeps it out of argv)
  if ! have wtype; then
    note "Vault" "wtype is not installed" critical
    cat >/dev/null
    return 1
  fi
  if ! tg_ok "$TYPE_PREV" vault; then
    cat >/dev/null   # drop the secret, nothing is typed
    return 1
  fi
  wtype -
}

passwords() {
  local rows out key pick id user pass
  if ((DRY)); then echo "rbw list --fields id,name,user,folder | fzf-menu -p vault ... (Enter: user<Tab>password via wtype -)"; return 0; fi
  need_ready || return 1
  have fzf-menu || { note "Vault" "fzf-menu is not installed" critical; return 1; }
  TYPE_PREV=$(tg_record)
  rows=$(rbw list --fields id,name,user,folder 2>/dev/null) || { note "Vault" "Could not read the vault (locked and cancelled?)" critical; return 1; }
  poke_bar
  [[ -n $rows ]] || { note "Vault" "The vault has no logins"; return 0; }
  export FZF_MENU_NORMAL_BINDS
  FZF_MENU_NORMAL_BINDS=$(nb p alt-p; echo; nb u alt-u; echo; nb y alt-c; echo; nb t alt-t)
  out=$(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s\t%-34s %-30s %s\n", $1, substr($2, 1, 34), substr($3, 1, 30), ($4 != "" ? "[" $4 "]" : "") }' |
    fzf-menu -p vault --delimiter=$'\t' --with-nth=2.. --expect=alt-p,alt-u,alt-c,alt-t \
      --header $'Enter: user+Tab+password   Alt+p / p: password   Alt+u / u: user   Alt+c / y: copy   Alt+t / t: TOTP' \
      --preview "$SELF pw-preview {1}" --preview-window 'right,45%,border-left') || return 0
  key=$(sed -n 1p <<<"$out")
  pick=$(sed -n 2p <<<"$out")
  id=${pick%%$'\t'*}
  [[ -n $id ]] || return 0
  user=$(awk -F'\t' -v id="$id" '$1 == id { print $3; exit }' <<<"$rows")
  case $key in
    alt-t)
      python3 -I "$TOTP_PY" copy "$id" ;;
    alt-c)
      pass=$(rbw get "$id") || { note "Vault" "Could not read the password" critical; return 1; }
      printf '%s' "$pass" | wl-copy --sensitive
      note "Password copied" "cleared in 30 s"
      arm_clear ;;
    alt-u)
      sleep 0.2
      printf '%s' "$user" | type_text ;;
    alt-p)
      pass=$(rbw get "$id") || { note "Vault" "Could not read the password" critical; return 1; }
      sleep 0.2
      printf '%s' "$pass" | type_text ;;
    *)
      pass=$(rbw get "$id") || { note "Vault" "Could not read the password" critical; return 1; }
      sleep 0.2
      # Tab and the password only follow a user name that was typed into the right window
      if printf '%s' "$user" | type_text && tg_ok "$TYPE_PREV" vault; then
        wtype -k Tab
        printf '%s' "$pass" | type_text
      fi ;;
  esac
  pass=""
  poke_bar
  return 0
}

# json_get JSON FIELD: one field of the vault-who.py answer
json_get() { jq -r --arg f "$2" '.[$f] // empty' <<<"$1"; }

# SUPER+CTRL+U: the Linux password of the user the focused window is asking for. Which user and whether typing is
# allowed is vault-who.py's call (read-only); the password is only read on the real path and never printed or logged.
user_pass() {
  local target who cls kind user rule detail action rows id out interactive=0 pass hint
  target=$(tg_record)
  TYPE_PREV=$target
  who=$(python3 -I "$WHO_PY" ${target:+--address "$target"}) || { note "Vault" "Could not inspect the focused window" critical; return 1; }
  cls=$(json_get "$who" class); kind=$(json_get "$who" kind); user=$(json_get "$who" user)
  rule=$(json_get "$who" rule); detail=$(json_get "$who" detail)
  case $kind in terminal | polkit) action='type' ;; *) action='copy' ;; esac
  if ((DRY)); then
    echo "window: class=${cls:-none} address=${target:-none} kind=$kind"
    echo "user: ${user:-unknown} (rule: $rule${detail:+; $detail})"
    if [[ $action == type ]]; then hint='wtype -, no Enter'; else hint='wl-copy --sensitive, cleared in 30 s'; fi
    if [[ -z $user ]]; then echo "action: picker over the $LINUX_FOLDER folder, then $action ($hint)"; else echo "action: $action ($hint)"; fi
    if have rbw && rbw unlocked >/dev/null 2>&1; then
      rows=$(rbw list --fields id,name,user,folder 2>/dev/null | awk -F'\t' -v f="$LINUX_FOLDER" '$4 == f')
      if [[ -z $rows ]]; then
        echo "item: folder $LINUX_FOLDER missing or empty"
      elif [[ -n $user ]]; then
        if awk -F'\t' -v n="$user" '$2 == n { f = 1 } END { exit !f }' <<<"$rows"; then echo "item: $LINUX_FOLDER/$user found"; else echo "item: $LINUX_FOLDER/$user missing (picker)"; fi
      fi
    else
      echo "item: not checked (vault locked)"
    fi
    return 0
  fi
  need_ready || return 1
  if [[ $action == type ]] && ! have wtype; then note "Vault" "wtype is not installed" critical; return 1; fi
  rbw unlocked >/dev/null 2>&1 || interactive=1   # the unlock prompt (pinentry) takes the focus for a moment
  rows=$(rbw list --fields id,name,user,folder 2>/dev/null) || { note "Vault" "Could not read the vault (locked and cancelled?)" critical; return 1; }
  poke_bar
  rows=$(awk -F'\t' -v f="$LINUX_FOLDER" '$4 == f' <<<"$rows")
  if [[ -z $rows ]]; then
    note "No \"$LINUX_FOLDER\" folder in the vault" "Create it: one login per Linux user, item name = user name, password = Linux password" critical
    return 1
  fi
  id=''
  [[ -n $user ]] && id=$(awk -F'\t' -v n="$user" '$2 == n { print $1; exit }' <<<"$rows")
  if [[ -z $id ]]; then
    have fzf-menu || { note "Vault" "fzf-menu is not installed" critical; return 1; }
    [[ -n $user ]] && note "No item \"$user\" in folder $LINUX_FOLDER" "Pick another one (or add the item)"
    if [[ $action == type ]]; then hint="type into ${cls:-the window}"; else hint="copy (not a terminal)"; fi
    out=$(awk -F'\t' '{ printf "%s\t%s\n", $1, $2 }' <<<"$rows" |
      fzf-menu -p linux --delimiter=$'\t' --with-nth=2.. --header "Linux user: Enter = $hint") || return 0
    interactive=1
    id=${out%%$'\t'*}
    [[ -n $id ]] || return 0
    user=$(awk -F'\t' -v i="$id" '$1 == i { print $2; exit }' <<<"$rows")
  fi
  pass=$(rbw get "$id") || { note "Vault" "Could not read the password" critical; return 1; }
  if [[ $action == copy ]]; then
    have wl-copy || { note "Vault" "wl-copy is not installed" critical; return 1; }
    printf '%s' "$pass" | wl-copy --sensitive
    pass=''
    note "Password of $user" "Not a terminal or password dialog: copied for 30 s instead" normal
    arm_clear
    return 0
  fi
  # the unlock prompt or the picker may have moved the focus: back to the window this key was pressed over (a verified
  # terminal / polkit window); without such a step a changed focus is refused by tg_ok below
  if ((interactive)) && [[ -n $target && $(tg_active) != "$target" ]] && have hyprd; then
    hyprd focuswindow "address:$target" >/dev/null 2>&1
    sleep 0.15
  fi
  sleep 0.1
  if printf '%s' "$pass" | type_text; then
    if [[ $kind == polkit ]]; then hint='into the polkit dialog'; else hint="into ${cls:-the terminal}"; fi
    note "Typed the password of $user" "$hint, no Enter"
  fi
  pass=''
  return 0
}

totp_rows() { python3 -I "$TOTP_PY" list; }

# the 2FA list; $@ = extra fzf-menu arguments (--here for a terminal). The preview ticks every second through the
# fzf --listen socket so the code and the countdown stay live.
totp_menu() {
  local rows sock loop out key pick id code
  if ((DRY)); then echo "python3 vault-totp.py list | fzf-menu -p 2fa ... (live preview)"; return 0; fi
  need_ready || return 1
  have fzf-menu || { note "Vault" "fzf-menu is not installed" critical; return 1; }
  TYPE_PREV=$(tg_record "$@")
  rows=$(totp_rows) || { note "Vault" "Could not read the vault (locked and cancelled?)" critical; return 1; }
  poke_bar
  [[ -n $rows ]] || { note "Vault" "No logins with a TOTP key. Import them: 2fa-import"; return 0; }
  mkdir -p "$RUN" && chmod 700 "$RUN"
  sock="$RUN/fzf-totp.$$.sock"
  rm -f "$sock"
  (
    while sleep 1; do
      [[ -S $sock ]] || continue
      curl -s --max-time 1 --unix-socket "$sock" -X POST http://localhost -d refresh-preview >/dev/null 2>&1 || true
    done
  ) &
  loop=$!
  local reload="reload(python3 -I '$TOTP_PY' list --refresh)"
  export FZF_MENU_NORMAL_BINDS
  FZF_MENU_NORMAL_BINDS=$(nb y alt-c; echo; nb t alt-t; echo; printf 'r:%s' "$reload")
  out=$(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s\t%s%s%s\n", $1, $2, ($3 != "" ? "   " $3 : ""), ($4 != "" ? "   [" $4 "]" : "") }' |
    fzf-menu "$@" -p 2fa --delimiter=$'\t' --with-nth=2.. --expect=alt-t,alt-c --listen="$sock" \
      --header $'Enter / y: copy the code (clears in 30 s)   Alt+t / t: type it   Alt+r / r: rescan' \
      --bind "alt-r:$reload" \
      --preview "python3 -I '$TOTP_PY' preview {1}" --preview-window 'right,45%,border-left') || true
  kill "$loop" 2>/dev/null
  wait "$loop" 2>/dev/null
  rm -f "$sock"
  key=$(sed -n 1p <<<"$out")
  pick=$(sed -n 2p <<<"$out")
  id=${pick%%$'\t'*}
  if [[ -n $id ]]; then
    if [[ $key == alt-t ]]; then
      code=$(python3 -I "$TOTP_PY" code "$id") || return 1
      sleep 0.2
      printf '%s' "$code" | type_text
    else
      python3 -I "$TOTP_PY" copy "$id"
    fi
  fi
  poke_bar
  return 0
}

# the vault browser: all the logic is in vault-browse.py (this only checks that rbw is ready)
browse() {
  if ((DRY)); then echo "python3 vault-browse.py $*   # fzf-menu list over rbw (bw for Trash, files, edit)"; return 0; fi
  need_ready || return 1
  have fzf-menu || { note "Vault" "fzf-menu is not installed" critical; return 1; }
  python3 -I "$BROWSE_PY" "$@"
}

lock() {
  local did=0
  if ((DRY)); then echo "rbw lock; python3 vault-bw.py lock   # both, when installed"; return 0; fi
  if ! have rbw && ! have bw; then
    note "Vault" "rbw is not installed" critical
    return 1
  fi
  forget_index
  if have rbw && rbw unlocked >/dev/null 2>&1; then rbw lock && did=1; fi
  if have bw && [[ -f $BW_SESSION_FILE ]]; then python3 -I "$BW_PY" lock && did=1; fi
  if ((did)); then
    note "Vault locked" "The master password is asked again on the next use"
  else
    note "Vault" "Already locked"
  fi
  poke_bar
}

sync_vault() {
  if ((DRY)); then echo "rbw sync; python3 vault-bw.py sync   # bw only when its session is open"; return 0; fi
  need_ready || return 1
  forget_index
  if rbw sync; then
    # the official CLI is synced too, but only when its session is already open (no second password prompt)
    if have bw && [[ -f $BW_SESSION_FILE ]]; then python3 -I "$BW_PY" sync >/dev/null 2>&1 || true; fi
    note "Vault synced"
  else
    note "Vault sync failed" "Check the server and the network" critical
  fi
  poke_bar
}

session_start() {
  if ((DRY)); then
    echo "rbw stop-agent   # one master password per login"
    echo "rm bw-session; python3 vault-bw.py lock   # the official CLI too"
    [[ -f $SSH_FLAG ]] && echo "start bitwarden-desktop silently (SSH agent flag is on)"
    return 0
  fi
  have rbw && { rbw stop-agent >/dev/null 2>&1 || true; }
  if have bw; then
    rm -f "$BW_SESSION_FILE"
    setsid -f python3 -I "$BW_PY" lock >/dev/null 2>&1 || true
  fi
  forget_index
  poke_bar
  # opt-in SSH agent: the desktop app owns the socket, so it has to run (start to tray is the app's own setting)
  if [[ -f $SSH_FLAG ]] && have bitwarden-desktop; then
    setsid -f bash -c 'sleep 6; pgrep -f "[b]itwarden/app\.asar" >/dev/null || hyprd exec "[silent] bitwarden-desktop" >/dev/null 2>&1' >/dev/null 2>&1 || true
  fi
  return 0
}

bw_cmd() {
  if ((DRY)); then echo "python3 vault-bw.py $*"; return 0; fi
  have bw || { note "Vault" "bw is not installed (sudo ./apply-system.sh --only install)" critical; return 1; }
  python3 -I "$BW_PY" "$@"
}

app() {
  if ((DRY)); then echo "bitwarden-desktop"; return 0; fi
  have bitwarden-desktop || { note "Vault" "The Bitwarden desktop app is not installed" critical; return 1; }
  setsid -f bitwarden-desktop >/dev/null 2>&1
}

web() {
  local url=''
  if ((DRY)); then echo "xdg-open <web vault URL from the rbw config>"; return 0; fi
  [[ -s $RBW_CONF ]] && url=$(jq -r '.ui_url // .base_url // empty' "$RBW_CONF" 2>/dev/null)
  url=${url:-https://vault.bitwarden.com}
  have xdg-open || { note "Vault" "xdg-open is not installed" critical; return 1; }
  setsid -f xdg-open "$url" >/dev/null 2>&1
}

ssh_agent() {
  local sock_state=absent
  [[ -S $SSH_SOCK ]] && sock_state=present
  case ${1:-status} in
    on)
      if ((DRY)); then echo "touch $SSH_FLAG   # shells use $SSH_SOCK while it exists"; return 0; fi
      mkdir -p "$STATE_DIR" && : >"$SSH_FLAG"
      echo "SSH agent flag: on. New shells use $SSH_SOCK while the socket exists (otherwise the current agent)."
      echo "In the Bitwarden app: Settings > Enable SSH agent, and Settings > Start to tray (so login does not open the window)."
      echo "Add a key in the app: New > SSH key. Verify: SSH_AUTH_SOCK=$SSH_SOCK ssh-add -L"
      have bitwarden-desktop || echo "The desktop app is not installed yet (sudo ./apply-system.sh --only install)."
      note "SSH agent from Bitwarden: on" "Enable it in the app (Settings > Enable SSH agent); new shells pick the socket up"
      ;;
    off)
      if ((DRY)); then echo "rm $SSH_FLAG"; return 0; fi
      rm -f "$SSH_FLAG"
      echo "SSH agent flag: off. New shells use the current agent again (open shells keep their value)."
      note "SSH agent from Bitwarden: off" "New shells use the previous agent again"
      ;;
    toggle)
      if [[ -f $SSH_FLAG ]]; then ssh_agent off; else ssh_agent on; fi
      ;;
    status)
      if [[ -f $SSH_FLAG ]]; then echo "SSH agent flag: on"; else echo "SSH agent flag: off"; fi
      echo "socket: $SSH_SOCK ($sock_state)"
      [[ -f $SSH_FLAG ]]
      ;;
    *) echo "usage: vault.sh ssh-agent on|off|toggle|status" >&2; return 2 ;;
  esac
}

waybar() {
  local st nl=$'\n' tip='L: passwords · M: desktop app · R: 2FA codes'
  st=$(state)
  [[ -f $BW_SESSION_FILE ]] && tip="CLI (bw): session open$nl$tip"
  [[ -f $SSH_FLAG ]] && tip="SSH agent: on ($([[ -S $SSH_SOCK ]] && echo socket up || echo app not running))$nl$tip"
  # colour roles: unlocked = normal (the usual state of a session, no colour), locked / not set up = dim
  case $st in
    missing) echo '{"text":""}' ;;
    unconfigured) jq -cn --arg t "$G_LOCKED" '{text: $t, class: "dim", tooltip: "Vault is not set up: run bw-setup in a terminal"}' ;;
    unlocked) jq -cn --arg t "$G_OPEN" --arg tip "Vault unlocked (until the next login or lock)$nl$nl$tip" '{text: $t, class: "normal", tooltip: $tip}' ;;
    *) jq -cn --arg t "$G_LOCKED" --arg tip "Vault locked (master password on first use)$nl$nl$tip" '{text: $t, class: "dim", tooltip: $tip}' ;;
  esac
}

case ${1:-passwords} in
  passwords) passwords ;;
  pw-preview) pw_preview "${2:?id}" ;;
  totp) totp_menu ;;
  totp-tui) totp_menu --here ;;
  browse) shift; browse "$@" ;;
  user-pass) user_pass ;;
  lock) lock ;;
  sync) sync_vault ;;
  status) state ;;
  waybar) waybar ;;
  session-start) session_start ;;
  arm-clear) arm_clear ;;
  bw) shift; bw_cmd "$@" ;;
  app) app ;;
  web) web ;;
  ssh-agent) shift; ssh_agent "$@" ;;
  *) echo "usage: vault.sh passwords|pw-preview ID|totp|totp-tui|browse [--here] [FOLDER]|user-pass|lock|sync|status|waybar|session-start|arm-clear|bw CMD|app|web|ssh-agent on|off|toggle|status [--dry-run]" >&2; exit 2 ;;
esac
