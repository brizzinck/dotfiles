#!/usr/bin/env bash
# Rollback of `sudo ./apply-system.sh --only users` (root). Idempotent, prints every step.
#   sudo infrastructure/users/rollback.sh            remove the sudoers drop-in and the polkit rule; give every managed user its ACL
#                                                    entries on the owner's home back (recursively, rwx on directories, rwX on files)
#   sudo infrastructure/users/rollback.sh --srv      also remove /srv/dotfiles and /srv/nvim-shared
#   sudo infrastructure/users/rollback.sh --home-acl also drop the owner's ACL from managed homes that had none before (yc)
# Not undone (never changed by the section): passwords, shells, groups, linger of td/yc, the user-level files in ~/dotfiles
# (revert those commits; `usr link --restore` as the managed user puts its old links back).
set -euo pipefail
[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"
OWNER="${SUDO_USER:-}"
if [ -z "$OWNER" ] || [ "$OWNER" = root ]; then echo "run this through sudo as the workstation owner" >&2; exit 1; fi
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=/var/lib/usr-managed
DO_SRV=0 DO_HOME=0
for a in "$@"; do
  case "$a" in
    --srv) DO_SRV=1 ;;
    --home-acl) DO_HOME=1 ;;
    -h | --help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
# shellcheck source=infrastructure/users/lib.sh
source "$HERE/lib.sh"

for f in /etc/sudoers.d/50-usr-managed /etc/polkit-1/rules.d/50-usr-managed.rules; do
  if [ -e "$f" ]; then rm -f -- "$f"; echo "removed $f"; else echo "absent: $f"; fi
done

for u in $(managed_users); do
  getent passwd "$u" >/dev/null || continue
  if ls "$STATE"/acl-before-"$u"-*.txt >/dev/null 2>&1; then
    echo "restoring the ACL entries of $u on $OWNER_HOME (reference: $(ls "$STATE"/acl-before-"$u"-*.txt | tail -1))"
    find "$OWNER_HOME" -xdev ! -type l -type d -exec setfacl -m "u:$u:rwx,d:u:$u:rwx" {} +
    find "$OWNER_HOME" -xdev ! -type l ! -type d -exec setfacl -n -m "u:$u:rwX" {} +
  else
    echo "no saved ACL state for $u: nothing to restore"
  fi
  if [ "$DO_HOME" = 1 ] && [ -e "$STATE/home-acl-added-$u" ]; then
    h="$(getent passwd "$u" | cut -d: -f6)"
    echo "dropping the owner's ACL from $h"
    find "$h" -xdev ! -type l -type d -exec setfacl -x "u:$OWNER,d:u:$OWNER" {} +
    find "$h" -xdev ! -type l ! -type d -exec setfacl -x "u:$OWNER" {} +
    rm -f -- "$STATE/home-acl-added-$u"
  fi
done

if [ "$DO_SRV" = 1 ]; then
  rm -rf -- /srv/dotfiles /srv/nvim-shared
  echo "removed /srv/dotfiles and /srv/nvim-shared"
fi
echo "done. The managed users have their old ACL on $OWNER_HOME again; passwordless become is gone."
