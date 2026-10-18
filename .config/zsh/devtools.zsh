# Shared dev tools (USERS-SYNC), sourced from .zshrc: a MANAGED user (td, yc) gets /srv/devtools/bin (lazysql, gh-dash, posting,
# gitlab-ci-local, glab-tui, workmux; filled by `infrastructure/dev/user-tools.sh --shared`) at the END of PATH, so their own
# installs win. The owner is unchanged. The tree counts only while nobody but its owner can change it:
#   - /srv/devtools is a real directory, owned by root or by the account named in /srv/devtools/.owner, with a bin/ directory;
#   - .owner is owned by that same account; the root dir, bin/, .owner and /srv itself are not group/other writable and /srv is
#     root's (the real /srv/devtools only);
#   - the user is not that account (a td-writable tree is never trusted).
# The same rule is `shared_bin()` in .config/devtools/devtools.py (the launchers' tool lookup); keep them in step.
# (zstat -s gives user names and the symbolic mode drwxr-xr-x: group write is character 6, other write character 9)
# Test hooks (DF_DEVTOOLS_TEST=1 only): DF_DEVTOOLS_ROOT replaces /srv/devtools (and skips the /srv check), DF_DEVTOOLS_ME the user name.
() {
  emulate -L zsh
  local root=/srv/devtools me=$USERNAME test=0
  if [[ $DF_DEVTOOLS_TEST == 1 ]]; then test=1; root=${DF_DEVTOOLS_ROOT:-$root}; me=${DF_DEVTOOLS_ME:-$me}; fi
  [[ -d $root/bin && ! -L $root ]] || return 0
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
  local -A r b o p
  local who
  zstat -s -H r -L $root 2>/dev/null && zstat -s -H b -L $root/bin 2>/dev/null || return 0
  [[ -d $root/bin && ! -L $root/bin ]] || return 0
  who=$r[uid]
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
  (( ${path[(Ie)$root/bin]} )) || path+=($root/bin)
}
