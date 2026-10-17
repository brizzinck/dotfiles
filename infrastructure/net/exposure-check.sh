#!/usr/bin/env bash
# Read-only analysis behind doctor net-exposure (also used by infrastructure/tests/net/run.sh). No root needed.
#   exposure-check.sh listeners [--all]   non-loopback listeners that listeners.allow does not list (--all: every one,
#                                         with the verdict); one "proto addr:port" line each
#   exposure-check.sh stale-rules         ACCEPT rules in ufw's user.rules/user6.rules that ufw-rules.conf does not account for
# TCP: every LISTEN socket. UDP: every unconnected socket below the ephemeral port range (above it a socket is a client
# socket that only receives replies; the firewall drops anything else).
# Test hooks: NET_SS_FILE (output of `ss -H -lntu`), NET_ALLOW_FILE, NET_RULES_CONF, NET_UFW_DIR, NET_PORT_LOW.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOW="${NET_ALLOW_FILE:-$HERE/listeners.allow}"
RULES_CONF="${NET_RULES_CONF:-$HERE/ufw-rules.conf}"
UFW_DIR="${NET_UFW_DIR:-/etc/ufw}"

listeners() {
  local all=0 low
  [ "${1:-}" = --all ] && all=1
  low="${NET_PORT_LOW:-$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)}"
  : "${low:=32768}"
  {
    if [ -n "${NET_SS_FILE:-}" ]; then cat "$NET_SS_FILE"; else ss -H -lntu 2>/dev/null; fi
  } | awk -v low="$low" -v all="$all" -v allowfile="$ALLOW" '
    BEGIN {
      while ((getline line < allowfile) > 0) {
        if (line ~ /^[[:space:]]*(#|$)/) continue
        split(line, f, /[[:space:]]+/)
        ok[f[1] " " f[2]] = 1
      }
    }
    {
      proto = $1; local = $5
      if (proto != "tcp" && proto != "udp") next
      if (proto == "tcp" && $2 != "LISTEN") next
      i = match(local, /:[^:]*$/)
      addr = substr(local, 1, i - 1); port = substr(local, i + 1)
      sub(/%.*$/, "", addr); gsub(/[\[\]]/, "", addr)
      if (addr ~ /^127\./ || addr == "::1") next
      if (proto == "udp" && port + 0 >= low + 0) next
      verdict = ((proto " " port) in ok) ? "allowed" : "UNLISTED"
      shown = (addr ~ /:/) ? "[" addr "]:" port : addr ":" port
      if (all) print proto, shown, verdict
      else if (verdict == "UNLISTED") print proto, shown
    }' | sort -u
}

# tokens (ports, ranges, interface names) of the active lines of ufw-rules.conf
rule_tokens() {
  grep -vE '^[[:space:]]*(#|$)' "$RULES_CONF" 2>/dev/null | tr ' \t' '\n\n' | grep -vE '^(allow|deny|reject|limit|in|out|from|to|any|port|proto|tcp|udp|on|comment|log|log-all|route)$' | sort -u
}

stale_rules() {
  local f line proto port iface tokens hit
  tokens="$(rule_tokens)"
  for f in "$UFW_DIR/user.rules" "$UFW_DIR/user6.rules"; do
    [ -r "$f" ] || continue
    grep -E '^-A ufw6?-user-(input|forward|output) .*-j ACCEPT' "$f" | while IFS= read -r line; do
      port="$(sed -n 's/.*--dports\? \([0-9:,]*\).*/\1/p' <<<"$line")"
      iface="$(sed -n 's/.*-i \([^ ]*\).*/\1/p' <<<"$line")"
      hit=0
      if [ -n "$port" ]; then
        # the range of ufw-rules.conf is "1714:1764", the same spelling as iptables
        grep -qxF -- "$port" <<<"$(sed 's#/\(tcp\|udp\)$##' <<<"$tokens")" && hit=1
      elif [ -n "$iface" ]; then
        grep -qxF -- "$iface" <<<"$tokens" && hit=1
      fi
      [ "$hit" = 1 ] || printf '%s: %s\n' "$(basename "$f")" "$line"
    done
  done
}

case "${1:-}" in
  listeners) shift; listeners "$@" ;;
  stale-rules) stale_rules ;;
  *) echo "usage: ${0##*/} listeners [--all] | stale-rules" >&2; exit 2 ;;
esac
