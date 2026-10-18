#!/usr/bin/env bash
# Test of vault-share (.config/hypr/scripts/vault-share.py): scope grammar and rendering (section 2); the broker sections follow
# with the broker itself. Nothing here touches the real vault or /etc.
#
#   run.sh [--quick] [--keep]     ONLY=2,4 picks sections
set -u
export PYTHONDONTWRITEBYTECODE=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPTS="$REPO/.config/hypr/scripts"
QUICK=0 KEEP=0
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; *) echo "usage: run.sh [--quick] [--keep]" >&2; exit 2 ;; esac; done
PASS=0 FAILS=0
FILT=",${ONLY:-},"
want() { [[ -z ${ONLY:-} || $FILT == *",$1,"* ]]; }
check() { local name=$1; shift; if "$@"; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$name"; else FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$name"; fi; }
VSH() { python3 -I -B "$SCRIPTS/vault-share.py" "$@"; }

section2() {
  local out rc d
  d=$(mktemp -d /tmp/vshare.XXXXXX)
  out=$(python3 -I -B "$HERE/scopes_test.py" 2>&1); rc=$?
  PASS=$((PASS + $(grep -c '^ok' <<<"$out")))
  FAILS=$((FAILS + $(grep -c '^FAIL' <<<"$out")))
  grep -E '^(ok|FAIL)' <<<"$out"
  ((rc == 0)) || { FAILS=$((FAILS + 1)); echo "FAIL  scopes_test.py exit $rc"; }
  # 2.2 CLI exit codes
  printf 'td\tShared/**\ntd\tUsers/td/**\n' >"$d/good.tsv"
  printf 'td\t**\n' >"$d/bad.tsv"
  printf 'skalse\tShared/**\n' >"$d/owner.tsv"
  VSH check-scopes "$d/good.tsv" --owner skalse >/dev/null 2>&1; check "2.2 check-scopes: good file exit 0" test $? = 0
  VSH check-scopes "$d/bad.tsv" --owner skalse >/dev/null 2>&1; check "2.2 check-scopes: bad rule exit 4" test $? = 4
  VSH check-scopes "$d/owner.tsv" --owner skalse >/dev/null 2>&1; check "2.2 check-scopes: a row for the owner exit 4" test $? = 4
  VSH check-scopes "$d/none.tsv" >/dev/null 2>&1; check "2.2 check-scopes: unreadable file exit 4" test $? = 4
  VSH check-scopes >/dev/null 2>&1; check "2.2 check-scopes: no argument exit 2" test $? = 2
  VSH bogus >/dev/null 2>&1; check "2.2 unknown command exit 2" test $? = 2
  # 2.3 render-scopes CLI with the overlay (0600) and its refusals
  printf 'td\tWork/Acme/**\nyc\tWork/Globex/**\n' >"$d/local.tsv"; chmod 600 "$d/local.tsv"
  out=$(VSH render-scopes --repo "$REPO/infrastructure/vault-share/scopes.tsv" --local "$d/local.tsv" --managed "td yc" --owner skalse 2>&1)
  check "2.3 render-scopes: generic + overlay rows, td and yc separate" bash -c '
    grep -qP "^td\tShared/\*\*$" <<<"$1" && grep -qP "^td\tUsers/td/\*\*$" <<<"$1" && grep -qP "^td\tWork/Acme/\*\*$" <<<"$1" \
    && grep -qP "^yc\tWork/Globex/\*\*$" <<<"$1" && ! grep -qP "^td\tWork/Globex" <<<"$1" && ! grep -qP "^yc\tWork/Acme" <<<"$1"' _ "$out"
  chmod 660 "$d/local.tsv"
  out=$(VSH render-scopes --repo "$REPO/infrastructure/vault-share/scopes.tsv" --local "$d/local.tsv" --managed "td yc" --owner skalse 2>&1)
  check "2.4 render-scopes: a group-writable overlay is ignored with a warning" bash -c '
    grep -q "ignored: group- or other-writable" <<<"$1" && ! grep -q "Work/Acme" <<<"$1"' _ "$out"
  ln -sf "$d/local.tsv" "$d/link.tsv"
  chmod 600 "$d/local.tsv"
  out=$(VSH render-scopes --repo "$REPO/infrastructure/vault-share/scopes.tsv" --local "$d/link.tsv" --managed "td yc" --owner skalse 2>&1)
  check "2.4 render-scopes: a symlinked overlay is ignored" bash -c 'grep -q "ignored" <<<"$1" && ! grep -q "Work/Acme" <<<"$1"' _ "$out"
  printf 'td\t**\n' >"$d/local.tsv"
  VSH render-scopes --repo "$REPO/infrastructure/vault-share/scopes.tsv" --local "$d/local.tsv" --managed "td yc" --owner skalse >/dev/null 2>&1
  check "2.5 render-scopes: an invalid overlay row exit 4" test $? = 4
  VSH check-scopes "$REPO/infrastructure/vault-share/scopes.tsv" --owner skalse >/dev/null 2>&1
  check "2.6 check-scopes: the repo scopes.tsv is rejected only for its * user (render first)" test $? = 4
  VSH render-scopes --repo "$REPO/infrastructure/vault-share/scopes.tsv" --managed "td yc" --owner skalse >"$d/rendered.tsv" 2>/dev/null
  VSH check-scopes "$d/rendered.tsv" --owner skalse >/dev/null 2>&1
  check "2.6 the rendered repo file passes check-scopes" test $? = 0
  rm -rf "$d"
}

section4() {
  local out rc
  out=$(BROKER_QUICK=$QUICK python3 -I -B "$HERE/broker_test.py" 2>&1); rc=$?
  PASS=$((PASS + $(grep -c '^ok' <<<"$out")))
  FAILS=$((FAILS + $(grep -c '^FAIL' <<<"$out")))
  grep -E '^(ok|FAIL|      timing)' <<<"$out"
  ((rc == 0)) || { FAILS=$((FAILS + 1)); echo "FAIL  broker_test.py exit $rc"; grep -v -E '^(ok|FAIL)' <<<"$out" | tail -15; }
}

check "broker subprocess timeout drains pipes and reaps child" python3 -I -B "$HERE/process_test.py"

want 2 && section2
want 4 && section4

echo
echo "passed $PASS, failed $FAILS"
exit $((FAILS > 0))
