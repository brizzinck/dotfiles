# Shared dev tools (USERS-SYNC), sourced from .zshrc and from the managed block that `usr link` writes into a managed user's own
# ~/.zshenv (so `zsh -c`, `zsh -lc`, `ssh td@host cmd` and `usr exec` get it too, not only the interactive shell; bash -l goes
# through the block in ~/.profile, which runs this file with DF_DEVTOOLS_PRINT=1 and appends what it prints).
# A MANAGED user (td, yc) gets /srv/devtools/bin (lazysql, gh-dash, posting, gitlab-ci-local, glab-tui, workmux; filled by
# `infrastructure/dev/user-tools.sh --shared`) at the END of PATH, so their own installs win. The owner is unchanged. The tree
# counts only while nobody but its owner can change it:
#   - /srv/devtools is a real directory, owned by root or by the account named in /etc/usr-managed/devtools-owner (root:root, written
#     by the users section; it cannot be forged by the account it names). Without that file (before the users section ran again)
#     the account named in /srv/devtools/.owner counts, that file owned by the same account;
#   - the root dir, bin/, .owner and /srv itself are not group/other writable and /srv is root's (the real /srv/devtools only);
#   - the user is not that account (a tree the user can write is never trusted; the account in the anchor never uses it).
# The same rule is `shared_bin()` in .config/devtools/devtools.py (the launchers' tool lookup); keep them in step.
# (zstat -s gives user names and the symbolic mode drwxr-xr-x: group write is character 6, other write character 9)
# Test hooks (DF_DEVTOOLS_TEST=1 only, and only for a root below /tmp, /var/tmp, /dev/shm or $TMPDIR that holds a file named
# .devtools-test): DF_DEVTOOLS_ROOT replaces /srv/devtools (and skips the root-ownership checks), DF_DEVTOOLS_ME the user name,
# DF_DEVTOOLS_ANCHOR the anchor file (none unless named).
() {
  emulate -L zsh
  local root=/srv/devtools me=$USERNAME anchor=/etc/usr-managed/devtools-owner test=0 aname="" tdir=${TMPDIR:-/tmp}
  if [[ $DF_DEVTOOLS_TEST == 1 && -n $DF_DEVTOOLS_ROOT && $DF_DEVTOOLS_ROOT == (/tmp|/var/tmp|/dev/shm|$tdir)/* \
        && -f $DF_DEVTOOLS_ROOT/.devtools-test && ! -L $DF_DEVTOOLS_ROOT/.devtools-test ]]; then
    test=1; root=$DF_DEVTOOLS_ROOT; me=${DF_DEVTOOLS_ME:-$me}; anchor=${DF_DEVTOOLS_ANCHOR:-}
  fi
  [[ -d $root/bin && ! -L $root ]] || return 0
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
  local -A r b o p a ad
  local who
  zstat -s -H r -L $root 2>/dev/null && zstat -s -H b -L $root/bin 2>/dev/null || return 0
  [[ -d $root/bin && ! -L $root/bin ]] || return 0
  who=$r[uid]
  if [[ -n $anchor && ( -e $anchor || -L $anchor ) ]]; then
    zstat -s -H a -L $anchor 2>/dev/null && [[ -f $anchor && ! -L $anchor && $a[mode] != (?????w*|????????w*) ]] || return 0
    zstat -s -H ad -L ${anchor:h} 2>/dev/null && [[ $ad[mode] != (?????w*|????????w*) ]] || return 0
    if (( ! test )); then [[ $a[uid] == root && $ad[uid] == root ]] || return 0; fi
    aname=$(<$anchor)
    aname=${aname%%$'\n'*}
    [[ -n $aname ]] || return 0
    [[ $who == root || $who == $aname ]] || return 0
    [[ $me != $aname ]] || return 0
  fi
  # root's own tree needs no .owner; any other owner must be named in it, by that same account
  if [[ $who != root ]]; then
    [[ -f $root/.owner && ! -L $root/.owner ]] && zstat -s -H o -L $root/.owner 2>/dev/null || return 0
    [[ $o[uid] == $who && $(<$root/.owner) == $who ]] || return 0
    [[ $o[mode] == (?????w*|????????w*) ]] && return 0
  fi
  [[ $who != $me ]] || return 0
  [[ $r[mode] == (?????w*|????????w*) ]] && return 0
  [[ $b[mode] == (?????w*|????????w*) ]] && return 0
  [[ $b[uid] == $who ]] || return 0
  if (( ! test )); then
    zstat -s -H p -L /srv 2>/dev/null && [[ $p[uid] == root && $p[mode] != (?????w*|????????w*) ]] || return 0
  fi
  if [[ -n $DF_DEVTOOLS_PRINT ]]; then print -r -- $root/bin; return 0; fi
  (( ${path[(Ie)$root/bin]} )) || path+=($root/bin)
}
