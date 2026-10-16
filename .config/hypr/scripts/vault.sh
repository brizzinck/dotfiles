#!/usr/bin/env bash
# vault: Bitwarden / Vaultwarden front end on top of rbw + rofi-rbw.
# SUPER+CTRL+P (passwords), SUPER+CTRL+O (2FA codes), waybar custom/vault, hub rows.
#
#   vault.sh passwords [ARGS]   rofi-rbw (Enter types user+password, Alt+t copies the TOTP; settings in ~/.config/rofi-rbw.rc)
#   vault.sh totp               rofi list of the logins that have a TOTP key: Enter copies the code, Alt+t types it,
#                               Alt+r rescans the vault
#   vault.sh totp-tui           same list in fzf with a live code + countdown preview (hub row, runs in a terminal)
#   vault.sh lock               lock the vault now (rbw lock)
#   vault.sh sync               rbw sync (asks for the master password when locked)
#   vault.sh status             print locked|unlocked|unconfigured|missing, exit 0 only when unlocked
#   vault.sh waybar             JSON for the custom/vault module (signal 15)
#   vault.sh session-start      Hyprland exec-once: stop the rbw agent left over from the previous login so the
#                               master password is asked once per login session (silent without rbw)
#   vault.sh arm-clear          clear the clipboard in 30 s if it still holds the same sensitive value
#   --dry-run                   print what would run, change nothing
#
# `rbw unlocked` is the only state probe: it never starts the agent and never opens pinentry (checked on rbw 1.15).
# Secrets are copied with wl-copy --sensitive (cliphist skips them), never shown in notifications, never written to disk.
set -u

HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
TOTP_PY="$HERE/vault-totp.py"
RUN="${XDG_RUNTIME_DIR:-/tmp}/vault"
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
  if ((DRY)); then echo "rbw lock"; return 0; fi
  have rbw || { note "Vault" "rbw is not installed" critical; return 1; }
  forget_index
  if rbw unlocked >/dev/null 2>&1; then
    rbw lock && note "Vault locked" "The master password is asked again on the next use"
  else
    note "Vault" "Already locked"
  fi
  poke_bar
}

sync_vault() {
  if ((DRY)); then echo "rbw sync"; return 0; fi
  need_ready || return 1
  forget_index
  if rbw sync; then
    note "Vault synced"
  else
    note "Vault sync failed" "Check the server and the network" critical
  fi
  poke_bar
}

session_start() {
  if ((DRY)); then echo "rbw stop-agent   # one master password per login"; return 0; fi
  have rbw || return 0
  rbw stop-agent >/dev/null 2>&1 || true
  forget_index
  poke_bar
  return 0
}

waybar() {
  local st nl=$'\n' tip='left: passwords  right: 2FA codes'
  st=$(state)
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
  *) echo "usage: vault.sh passwords|totp|totp-tui|lock|sync|status|waybar|session-start|arm-clear [--dry-run]" >&2; exit 2 ;;
esac
