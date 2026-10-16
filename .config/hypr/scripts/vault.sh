#!/usr/bin/env bash
# vault: Bitwarden / Vaultwarden front end on top of rbw + rofi-rbw.
# SUPER+CTRL+P (passwords), SUPER+CTRL+O (2FA codes), waybar custom/vault, hub rows.
#
#   vault.sh passwords [ARGS]   rofi-rbw (Enter types user+password, Alt+t copies the TOTP; settings in ~/.config/rofi-rbw.rc)
#   vault.sh totp               rofi list of the logins that have a TOTP key: Enter copies the code, Alt+t types it,
#                               Alt+r rescans the vault
#   vault.sh totp-tui           same list in fzf with a live code + countdown preview (hub row, runs in a terminal)
#   vault.sh lock               lock the vault now: rbw lock and the official CLI session (bw lock)
#   vault.sh sync               rbw sync (asks for the master password when locked) and, when its session is open, bw sync
#   vault.sh status             print locked|unlocked|unconfigured|missing, exit 0 only when unlocked
#   vault.sh waybar             JSON for the custom/vault module (signal 15)
#   vault.sh session-start      Hyprland exec-once: stop the rbw agent and drop the bw session left over from the
#                               previous login so the master password is asked once per login session (silent without
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
# Everforest fzf colours of the active variant (generated, see themes/palette); callers outside a login shell have no env
: "${FZF_DEFAULT_OPTS_FILE:=${XDG_STATE_HOME:-$HOME/.local/state}/theme/current/fzfrc}"
if [[ -r $FZF_DEFAULT_OPTS_FILE ]]; then export FZF_DEFAULT_OPTS_FILE; else unset FZF_DEFAULT_OPTS_FILE; fi

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
TOTP_PY="$HERE/vault-totp.py"
BW_PY="$HERE/vault-bw.py"
RUN="${XDG_RUNTIME_DIR:-/tmp}/vault"
BW_SESSION_FILE="$RUN/bw-session"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vault"
SSH_FLAG="$STATE_DIR/ssh-agent"
SSH_SOCK="${BITWARDEN_SSH_AUTH_SOCK:-$HOME/.bitwarden-ssh-agent.sock}"
RBW_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/rbw/config.json"
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
poke_bar() { pkill -RTMIN+15 waybar 2>/dev/null || true; }
forget_index() { rm -f "$RUN/totp-index.tsv" "$RUN/totp-index.tmp"; }

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

passwords() {
  if ((DRY)); then echo "rofi-rbw $*"; return 0; fi
  need_ready || return 1
  have rofi-rbw || { note "Vault" "rofi-rbw is not installed" critical; return 1; }
  rofi-rbw "$@"
  local rc=$?
  arm_clear
  poke_bar
  return $rc
}

totp_rows() { python3 -I "$TOTP_PY" list "$@"; }

totp() {
  local rows pick rc id code
  if ((DRY)); then echo "python3 vault-totp.py list | rofi -dmenu ..."; return 0; fi
  need_ready || return 1
  have rofi || { note "Vault" "rofi is not installed" critical; return 1; }
  rows=$(totp_rows) || { note "Vault" "Could not read the vault (locked and cancelled?)" critical; return 1; }
  poke_bar
  while true; do
    [[ -n $rows ]] || { note "Vault" "No logins with a TOTP key. Import them: 2fa-import"; return 0; }
    rc=0
    pick=$(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s\t%s%s%s\n", $1, $2, ($3 != "" ? "   " $3 : ""), ($4 != "" ? "   [" $4 "]" : "") }' |
      rofi -dmenu -i -p 2fa -display-columns 2 -kb-custom-1 'Alt+t' -kb-custom-2 'Alt+r' \
        -mesg 'Enter: copy the code (clears after 30 s)    Alt+t: type it    Alt+r: rescan') || rc=$?
    id=${pick%%$'\t'*}
    case $rc in
      0) python3 -I "$TOTP_PY" copy "$id"; return $? ;;
      10)
        have wtype || { note "Vault" "wtype is not installed" critical; return 1; }
        code=$(python3 -I "$TOTP_PY" code "$id") || return 1
        printf '%s' "$code" | wtype -
        return 0 ;;
      11) rows=$(totp_rows --refresh) || return 1 ;;
      *) return 0 ;;
    esac
  done
}

totp_tui() {
  local rows sock loop
  need_ready || { read -r -n1 -p 'press a key '; return 1; }
  have fzf || { echo "fzf is not installed"; read -r -n1; return 1; }
  rows=$(totp_rows) || { echo "could not read the vault"; read -r -n1 -p 'press a key '; return 1; }
  [[ -n $rows ]] || { echo "No logins with a TOTP key. Import them with: 2fa-import"; read -r -n1 -p 'press a key '; return 0; }
  mkdir -p "$RUN" && chmod 700 "$RUN"
  sock="$RUN/fzf-totp.$$.sock"
  rm -f "$sock"
  # tick the preview every second so the code and the countdown stay live
  (
    while sleep 1; do
      [[ -S $sock ]] || continue
      curl -s --max-time 1 --unix-socket "$sock" -X POST http://localhost -d refresh-preview >/dev/null 2>&1 || true
    done
  ) &
  loop=$!
  printf '%s\n' "$rows" | fzf --listen="$sock" --delimiter=$'\t' --with-nth=2,3 --tabstop=4 \
    --prompt='2fa> ' --height=100% --layout=reverse --border=none \
    --header='Enter: copy the code (sensitive, clears in 30 s)    Ctrl-R: rescan    Esc: close' \
    --preview="python3 -I '$TOTP_PY' preview {1}" --preview-window='right,45%,border-left' \
    --bind "enter:execute-silent(python3 -I '$TOTP_PY' copy {1})+abort" \
    --bind "ctrl-r:reload(python3 -I '$TOTP_PY' list --refresh)" || true
  kill "$loop" 2>/dev/null
  wait "$loop" 2>/dev/null
  rm -f "$sock"
  poke_bar
  return 0
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
    setsid -f bash -c 'sleep 6; pgrep -f "[b]itwarden/app\.asar" >/dev/null || hyprctl dispatch exec "[silent] bitwarden-desktop" >/dev/null 2>&1' >/dev/null 2>&1 || true
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
  local st nl=$'\n' tip='left: passwords  right: 2FA codes  middle: desktop app'
  st=$(state)
  [[ -f $BW_SESSION_FILE ]] && tip="$tip${nl}CLI (bw): session open"
  [[ -f $SSH_FLAG ]] && tip="$tip${nl}SSH agent: on ($([[ -S $SSH_SOCK ]] && echo socket up || echo app not running))"
  case $st in
    missing) echo '{"text":""}' ;;
    unconfigured) jq -cn --arg t "$G_LOCKED" '{text: $t, class: "unconfigured", tooltip: "Vault is not set up: run bw-setup in a terminal"}' ;;
    unlocked) jq -cn --arg t "$G_OPEN" --arg tip "Vault unlocked (until the next login or lock)$nl$tip" '{text: $t, class: "unlocked", tooltip: $tip}' ;;
    *) jq -cn --arg t "$G_LOCKED" --arg tip "Vault locked (master password on first use)$nl$tip" '{text: $t, class: "locked", tooltip: $tip}' ;;
  esac
}

case ${1:-passwords} in
  passwords) shift; passwords "$@" ;;
  totp) totp ;;
  totp-tui) totp_tui ;;
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
  *) echo "usage: vault.sh passwords|totp|totp-tui|lock|sync|status|waybar|session-start|arm-clear|bw CMD|app|web|ssh-agent on|off|toggle|status [--dry-run]" >&2; exit 2 ;;
esac
