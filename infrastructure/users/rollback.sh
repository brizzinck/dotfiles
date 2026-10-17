#!/usr/bin/env bash
# Rollback of `sudo ./apply-system.sh --only users` (root). Idempotent, prints every step.
#   sudo infrastructure/users/rollback.sh            remove the sudoers drop-in and the polkit rule; give every managed user its ACL
#                                                    entries on the owner's home back (recursively, rwx on directories, rwX on files)
#   sudo infrastructure/users/rollback.sh --srv      also remove /srv/dotfiles and /srv/nvim-shared
#   sudo infrastructure/users/rollback.sh --home-acl also drop the owner's ACL from managed homes that had none before (yc)
#   sudo infrastructure/users/rollback.sh --home-acl-cleanup
#                                              ONLY this, nothing else (it cannot be combined with the options above, the sudoers
#                                              rule and the managed users' ACL on the home stay as they are): put back what
#                                              home-acl.sh stripped from the owner's home (the ACL skeletons, from every
#                                              home-acl-before-*.txt.gz, oldest first) and the modes of the secret locations (every
#                                              secret-modes-before-*.txt). Done as the owner, only paths the owner owns, no symlink
#                                              is followed, nothing is chowned. Rarely wanted: the skeletons are what made new files
#                                              0650/0750; the marker file is removed so doctor's home-acl check goes back to INFO
# Not undone (never changed by the section): passwords, shells, groups, linger of td/yc, the user-level files in ~/dotfiles
# (revert those commits; `usr link --restore` as the managed user puts its old links back).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO_SRV=0 DO_HOME=0 DO_CLEAN=0
for a in "$@"; do
  case "$a" in
    --srv) DO_SRV=1 ;;
    --home-acl) DO_HOME=1 ;;
    --home-acl-cleanup) DO_CLEAN=1 ;;
    -h | --help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
if [ "$DO_CLEAN" = 1 ] && [ $((DO_SRV + DO_HOME)) -gt 0 ]; then
  echo "--home-acl-cleanup runs alone (it undoes only the home cleanup); run the other rollback steps separately" >&2
  exit 2
fi
# test hooks, honoured only without root (so a sudo run can never be redirected): ROLLBACK_TEST=1 plus ROLLBACK_OWNER,
# ROLLBACK_STATE, ROLLBACK_ETC (prefix of /etc), ROLLBACK_SRV (prefix of /srv)
if [ "${ROLLBACK_TEST:-}" = 1 ] && [ "$EUID" -ne 0 ]; then
  OWNER="${ROLLBACK_OWNER:?}" STATE="${ROLLBACK_STATE:?}" ETC="${ROLLBACK_ETC:-}" SRV="${ROLLBACK_SRV:-}"
else
  [ "$EUID" -eq 0 ] || exec sudo "$0" "$@"
  OWNER="${SUDO_USER:-}" STATE=/var/lib/usr-managed ETC="" SRV=""
fi
if [ -z "$OWNER" ] || [ "$OWNER" = root ]; then echo "run this through sudo as the workstation owner" >&2; exit 1; fi
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
# shellcheck source=infrastructure/users/lib.sh
source "$HERE/lib.sh"

if [ "$DO_CLEAN" = 1 ]; then
  # cleanup only: home-acl.sh restore does the work as the owner (runuser) and removes the marker
  "$HERE/home-acl.sh" restore --root "$OWNER_HOME" --owner "$OWNER" --state "$STATE"
  echo "done. Only the home ACL cleanup was undone; sudoers, polkit and the managed users' ACL are unchanged."
  exit 0
fi

for f in "$ETC"/etc/sudoers.d/50-usr-managed "$ETC"/etc/polkit-1/rules.d/50-usr-managed.rules; do
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
  rm -rf -- "$SRV"/srv/dotfiles "$SRV"/srv/nvim-shared
  echo "removed $SRV/srv/dotfiles and $SRV/srv/nvim-shared"
fi
echo "done. The managed users have their old ACL on $OWNER_HOME again; passwordless become is gone."
