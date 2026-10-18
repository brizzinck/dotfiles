#!/usr/bin/env bash
# Shared reader of managed.tsv (sourced by apply-system.sh, .local/bin/usr, doctor.sh). No side effects when sourced.
#   managed_tsv                    path of the registry (USR_MANAGED_TSV overrides it, used by the tests)
#   managed_users [CAP]            names, one per line; CAP filters by a capability:
#                                  interactive | service | become | acl | clipboard | wayland | create | profile
#   managed_has USER CAP           exit 0 when USER has the capability
#   managed_field USER NAME        profile | flags | accent | note
#   managed_validate OWNER         print one problem per line (empty output = valid)
# Capabilities: interactive = not `service`; become = not `nobecome`; acl = not `noacl`; profile = a profile other than `-`.
# bash 4+.

_USR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

managed_tsv() { printf '%s\n' "${USR_MANAGED_TSV:-$_USR_LIB_DIR/managed.tsv}"; }

# rows as "user<TAB>profile<TAB>flags<TAB>accent" (blank/comment lines dropped, missing columns become `-`)
_managed_rows() {
  local f
  f="$(managed_tsv)"
  [ -r "$f" ] || return 0
  awk -F'\t' 'BEGIN { OFS = "\t" }
    /^[[:space:]]*(#|$)/ { next }
    { for (i = 1; i <= 4; i++) if ($i == "") $i = "-"; print $1, $2, $3, $4 }' "$f"
}

managed_field() {
  local user="$1" name="$2" col
  case "$name" in
    profile) col=2 ;;
    flags) col=3 ;;
    accent) col=4 ;;
    note) col=5 ;;
    *) return 2 ;;
  esac
  awk -F'\t' -v u="$user" -v c="$col" '/^[[:space:]]*(#|$)/ { next } $1 == u { print ($c == "" ? "-" : $c); exit }' "$(managed_tsv)"
}

managed_has() {
  local user="$1" cap="$2" flags profile
  flags=",$(managed_field "$user" flags),"
  case "$cap" in
    service) [[ $flags == *,service,* ]] ;;
    interactive) [[ $flags != *,service,* ]] ;;
    become) [[ $flags != *,nobecome,* ]] ;;
    acl) [[ $flags != *,noacl,* ]] ;;
    clipboard) [[ $flags == *,clipboard,* ]] ;;
    wayland) [[ $flags == *,wayland,* || $flags == *,clipboard,* ]] ;;   # a clipboard user reaches the Wayland socket too
    create) [[ $flags == *,create,* ]] ;;
    profile) profile="$(managed_field "$user" profile)"; [ -n "$profile" ] && [ "$profile" != - ] ;;
    *) return 2 ;;
  esac
}

managed_users() {
  local cap="${1:-}" u
  while IFS=$'\t' read -r u _; do
    [ -n "$u" ] || continue
    if [ -z "$cap" ] || managed_has "$u" "$cap"; then printf '%s\n' "$u"; fi
  done < <(_managed_rows)
}

managed_validate() {
  local owner="$1" u profile flags seen=" " dir
  dir="$_USR_LIB_DIR"
  while IFS=$'\t' read -r u profile flags _; do
    [ -n "$u" ] || continue
    [[ $u =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "invalid user name: $u"; continue; }
    [ "$u" = root ] && echo "root must never be managed"
    [ "$u" = "$owner" ] && echo "the owner ($owner) must not be listed as managed"
    [[ $seen == *" $u "* ]] && echo "duplicate user: $u"
    seen="$seen$u "
    case ",$flags," in
      *,service,*) [ "$profile" = - ] || echo "$u: a service user cannot have a dotfiles profile ($profile)" ;;
    esac
    if [ "$profile" != - ] && [ ! -r "$dir/profiles/$profile.txt" ]; then echo "$u: profile $profile has no profiles/$profile.txt"; fi
    local f
    for f in ${flags//,/ }; do
      case "$f" in service | noacl | nobecome | clipboard | wayland | create | interactive | -) ;; *) echo "$u: unknown flag $f" ;; esac
    done
  done < <(_managed_rows)
}

# Exact private-layer membership: existing interactive accounts with a profile.
# Service users and the publisher are never added by this mechanism.
private_publish_members() {
  local u
  for u in $(managed_users profile); do
    managed_has "$u" interactive && getent passwd "$u" >/dev/null && printf '%s\n' "$u"
  done
}
