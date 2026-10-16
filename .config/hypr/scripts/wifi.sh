#!/usr/bin/env bash
# Wi-Fi picker on nmcli in fzf-menu (vim keys; nmtui has none). SUPER+I. `nmtui` stays as a hub row fallback.
#   Enter        connect (a saved profile is activated; a new secured network asks for the password in a themed
#                pinentry, the password goes to nmcli on stdin, never into argv)
#   Alt+d / d    forget the saved profile of the highlighted network
#   Alt+r / r    switch the Wi-Fi radio on/off
#   Alt+s / s    rescan                      (the list also rescans once when the menu opens)
#   wifi.sh --list              rows: SSID <TAB> marker, signal, security, SSID
#   wifi.sh --header            the header line (radio state)
#   wifi.sh --connect SSID      connect without the menu; --forget SSID; --radio on|off|toggle; --rescan
#   --dry-run (first argument)  print the nmcli commands instead of running them (listing still reads nmcli)
set -u
SELF=$(readlink -f "${BASH_SOURCE[0]}")
PINENTRY="${WIFI_PINENTRY:-pinentry-themed}"
DRY=0
[[ ${1:-} == --dry-run ]] && { DRY=1; shift; }

have() { command -v "$1" >/dev/null 2>&1; }
note() { notify-send -a wifi -t 3500 -h string:x-dunst-stack-tag:wifi "$1" "${2:-}" 2>/dev/null || true; }
nm() { if ((DRY)); then echo "nmcli $*"; else nmcli "$@"; fi; }

radio_state() { nmcli radio wifi 2>/dev/null || echo unknown; }

saved_names() { nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2 == "802-11-wireless" { print $1 }'; }

rows() {
  local saved
  saved=$(saved_names)
  # IN-USE:SSID:SIGNAL:SECURITY (nmcli escapes colons in the SSID as \:); a small python helper does the parsing
  nmcli -t -e yes -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no 2>/dev/null |
    python3 -I -c '
import re, sys
saved = set(sys.argv[1].split("\n")) if sys.argv[1] else set()
best = {}
for line in sys.stdin:
    parts = re.split(r"(?<!\\):", line.rstrip("\n"))
    if len(parts) < 4:
        continue
    use, ssid, sig, sec = parts[0], parts[1].replace("\\:", ":").replace("\\\\", "\\"), parts[2], parts[3]
    if not ssid or "\t" in ssid:
        continue
    try:
        sig = int(sig)
    except ValueError:
        sig = 0
    cur = best.get(ssid)
    if cur is None or use == "*" or (cur[0] != "*" and sig > cur[1]):
        best[ssid] = (use, sig, sec)
def bars(s):
    return "▂▄▆█"[: max(1, min(4, (s + 24) // 25))].ljust(4)
for ssid, (use, sig, sec) in sorted(best.items(), key=lambda kv: (kv[1][0] != "*", -kv[1][1])):
    mark = "●" if use == "*" else ("★" if ssid in saved else " ")
    lock = sec if sec and sec != "--" else "open"
    print(f"{ssid}\t{mark} {ssid:<32.32} {bars(sig)} {sig:>3}%  {lock}")
' "$saved"
}

header() {
  local r
  r=$(radio_state)
  printf 'Wi-Fi radio: %s   Enter connect  Alt+d/d forget  Alt+r/r radio  Alt+s/s rescan   ● connected  ★ saved' "$r"
}

ask_password() { # ssid -> the password on stdout (themed pinentry, nothing in argv)
  have "$PINENTRY" || return 1
  local out
  out=$(printf 'SETTITLE Wi-Fi\nSETDESC Password for the network %s\nSETPROMPT Password:\nGETPIN\n' "${1//%/%25}" | "$PINENTRY" 2>/dev/null) || return 1
  sed -n 's/^D //p' <<<"$out" | head -1
}

connect() { # ssid
  local ssid=$1 pw
  if saved_names | grep -qxF -- "$ssid"; then
    if nm connection up id "$ssid" >/dev/null; then note "Wi-Fi" "connected: $ssid"; else note "Wi-Fi" "could not connect to $ssid"; fi
    return
  fi
  if nmcli -t -f SSID,SECURITY device wifi list --rescan no 2>/dev/null | awk -F: -v s="$ssid" '$1 == s && $2 != "" && $2 != "--" { f = 1 } END { exit !f }'; then
    if ((DRY)); then echo "pinentry password -> printf pw | nmcli --ask device wifi connect '$ssid'"; return 0; fi
    pw=$(ask_password "$ssid") || { note "Wi-Fi" "cancelled"; return 0; }
    [[ -n $pw ]] || return 0
    if printf '%s\n' "$pw" | nmcli --ask device wifi connect "$ssid" >/dev/null 2>&1; then note "Wi-Fi" "connected: $ssid"; else note "Wi-Fi" "could not connect to $ssid (wrong password?)"; fi
    pw=""
  else
    if nm device wifi connect "$ssid" >/dev/null; then note "Wi-Fi" "connected: $ssid"; else note "Wi-Fi" "could not connect to $ssid"; fi
  fi
}

case ${1:-} in
  --list) rows; exit 0 ;;
  --header) header; exit 0 ;;
  --rescan) nm device wifi rescan >/dev/null 2>&1; exit 0 ;;
  --connect) connect "${2:?ssid}"; exit 0 ;;
  --forget) nm connection delete id "${2:?ssid}" >/dev/null 2>&1; exit 0 ;;
  --radio)
    case ${2:-toggle} in
      on | off) nm radio wifi "$2" ;;
      toggle) if [[ $(radio_state) == enabled ]]; then nm radio wifi off; else nm radio wifi on; sleep 1.5; fi ;;
    esac
    exit 0 ;;
esac

have nmcli || { note "Wi-Fi" "nmcli is not installed"; exit 1; }
have fzf-menu || { note "Wi-Fi" "fzf-menu is missing"; exit 1; }
[[ $(radio_state) == enabled ]] && nmcli device wifi rescan >/dev/null 2>&1 &
reload="reload($SELF --list)+transform-header($SELF --header)"
export FZF_MENU_NORMAL_BINDS="d:execute-silent($SELF --forget {1})+$reload
r:execute-silent($SELF --radio toggle)+$reload
s:execute-silent($SELF --rescan)+$reload"
ssid=$(rows | fzf-menu -p wifi --delimiter=$'\t' --with-nth=2.. --accept-nth=1 --no-sort --header "$(header)" \
  --bind "alt-d:execute-silent($SELF --forget {1})+$reload" \
  --bind "alt-r:execute-silent($SELF --radio toggle)+$reload" \
  --bind "alt-s:execute-silent($SELF --rescan)+$reload") || exit 0
[[ -n $ssid ]] || exit 0
connect "$ssid"
