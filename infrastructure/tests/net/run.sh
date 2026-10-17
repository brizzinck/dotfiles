#!/usr/bin/env bash
# Offline tests of the network-exposure part (apply-system.sh --only net, infrastructure/net/exposure-check.sh).
# No sudo, nothing on the machine is changed (the dry run only prints). Run: infrastructure/tests/net/run.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
NET="$REPO/infrastructure/net"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
expect() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }

# ── listener analysis on a fixture (ss -H -lntu) ────────────────────────────────
cat >"$T/ss" <<'SS'
udp UNCONN 0 0 127.0.0.54:53 0.0.0.0:*
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*
udp UNCONN 0 0 192.168.1.7:52528 0.0.0.0:*
udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*
udp UNCONN 0 0 [::]:5353 [::]:*
udp UNCONN 0 0 0.0.0.0:5355 0.0.0.0:*
udp UNCONN 0 0 [fdd3:fafe::1]:40451 [::]:*
tcp LISTEN 0 4096 127.0.0.1:8766 0.0.0.0:*
tcp LISTEN 0 2048 0.0.0.0:8788 0.0.0.0:*
tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*
tcp LISTEN 0 4096 [::1]:631 [::]:*
tcp LISTEN 0 4096 *:2017 *:*
tcp LISTEN 0 4096 *:3488 *:*
tcp LISTEN 0 4096 [::]:5355 [::]:*
tcp ESTAB 0 0 192.168.1.7:44444 1.2.3.4:443
SS
cat >"$T/allow" <<'AL'
# comment
tcp 3488  ch-ui
udp 5353  mdns
AL
got="$(NET_SS_FILE="$T/ss" NET_ALLOW_FILE="$T/allow" NET_PORT_LOW=32768 "$NET/exposure-check.sh" listeners)"
want="$(printf '%s\n' 'tcp *:2017' 'tcp 0.0.0.0:8788' 'tcp [::]:5355' 'udp 0.0.0.0:5355' | sort -u)"
expect "unlisted listeners (loopback, ephemeral UDP, ESTAB, allowlisted ones are not reported)" "$want" "$got"
got="$(NET_SS_FILE="$T/ss" NET_ALLOW_FILE="$T/allow" NET_PORT_LOW=32768 "$NET/exposure-check.sh" listeners --all | grep -c allowed)"
expect "allowlisted listeners are shown by --all (tcp 3488, udp 5353 v4 and v6)" 3 "$got"
got="$(NET_SS_FILE="$T/ss" NET_ALLOW_FILE=/dev/null NET_PORT_LOW=32768 "$NET/exposure-check.sh" listeners | grep -c .)"
expect "empty allowlist: every non-loopback listener below the ephemeral range is reported" 7 "$got"
# the shipped allowlist only names tcp/udp + port + a reason
if grep -vE '^[[:space:]]*(#|$)' "$NET/listeners.allow" | awk '$1 !~ /^(tcp|udp)$/ || $2 !~ /^[0-9]+$/ || NF < 3 {exit 1}'; then ok; else bad "listeners.allow has a malformed line"; fi

# ── stale ufw rules: anything user.rules accepts that ufw-rules.conf does not account for ─────────────────
mkdir -p "$T/ufw"
cat >"$T/ufw/user.rules" <<'UR'
*filter
### tuple ### allow tcp 1080 0.0.0.0/0 any 0.0.0.0/0 in
-A ufw-user-input -p tcp --dport 1080 -j ACCEPT
### tuple ### allow tcp 1714:1764 0.0.0.0/0 any 192.168.1.0/24 in
-A ufw-user-input -p tcp --dport 1714:1764 -s 192.168.1.0/24 -j ACCEPT
### tuple ### allow any any 0.0.0.0/0 any 0.0.0.0/0 in_tailscale0
-A ufw-user-input -i tailscale0 -j ACCEPT
-A ufw-user-limit -j REJECT
COMMIT
UR
: >"$T/ufw/user6.rules"
printf '%s\n' "# nothing active" >"$T/rules-empty"
got="$(NET_UFW_DIR="$T/ufw" NET_RULES_CONF="$T/rules-empty" "$NET/exposure-check.sh" stale-rules | wc -l)"
expect "no active rules in the repo list: all three user rules are stale" 3 "$got"
printf '%s\n' "allow in from 192.168.1.0/24 to any port 1714:1764 proto tcp" "allow in on tailscale0" >"$T/rules-two"
got="$(NET_UFW_DIR="$T/ufw" NET_RULES_CONF="$T/rules-two" "$NET/exposure-check.sh" stale-rules)"
expect "rules the repo list names are not stale (only port 1080 is)" "user.rules: -A ufw-user-input -p tcp --dport 1080 -j ACCEPT" "$got"
# the shipped rules file: no active rule yet, and the disabled examples are there
if grep -qvE '^[[:space:]]*(#|$)' "$NET/ufw-rules.conf"; then bad "ufw-rules.conf has an active rule (the shipped list is empty on purpose)"; else ok; fi
grep -q '^#allow in on tailscale0$' "$NET/ufw-rules.conf" && ok || bad "ufw-rules.conf lacks the disabled tailscale0 line"
[ "$(grep -c '^#allow .*1714:1764' "$NET/ufw-rules.conf")" = 2 ] && ok || bad "ufw-rules.conf lacks the disabled KDE Connect tcp+udp lines"

# ── drop-ins ────────────────────────────────────────────────────────────────────
grep -qx 'LLMNR=no' "$NET/10-no-llmnr.conf" && grep -qx '\[Resolve\]' "$NET/10-no-llmnr.conf" && ok || bad "10-no-llmnr.conf is not [Resolve] LLMNR=no"
grep -qx 'Environment=V2RAYA_ADDRESS=127.0.0.1:2017' "$NET/v2raya-loopback.conf" && ok || bad "v2raya drop-in does not bind 127.0.0.1:2017"
if grep -qE 'rp_filter|ip_forward' <(grep -v '^#' "$NET/ufw-sysctl.conf"); then bad "ufw-sysctl.conf sets rp_filter or ip_forward"; else ok; fi

# ── apply-system.sh --only net, dry run ─────────────────────────────────────────
dry="$("$REPO/apply-system.sh" --dry-run --only net 2>&1)"
for want in "10-no-llmnr.conf" "v2raya.service.d/10-loopback.conf" "/etc/ufw/dotfiles-sysctl.conf" "ufw --force enable" "systemctl enable ufw.service"; do
  case "$dry" in *"$want"*) ok ;; *) bad "dry run does not mention: $want" ;; esac
done
if printf '%s\n' "$dry" | grep -E '^\[dry-run\] (rm|ufw (reset|delete)|systemctl (stop|disable|mask))' >/dev/null; then bad "dry run would remove or stop something"; else ok; fi
if "$REPO/apply-system.sh" --dry-run --only net >/dev/null 2>&1; then ok; else bad "dry run exits non-zero"; fi
bash -n "$REPO/apply-system.sh" && ok || bad "apply-system.sh has a syntax error"

printf 'net tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
