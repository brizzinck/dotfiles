# One shell source, with a transitional legacy-only fallback. No vault calls.
_df_source_private_env() {
  emulate -L zsh
  unsetopt xtrace verbose
  zmodload -F zsh/stat b:zstat || return 1
  local home file legacy=0 part line kind who rights mask publisher=-1 anchor=/etc/usr-managed/devtools-owner name permissions
  local -A info
  # ~user consults passwd, not a project-controlled HOME/XDG value.
  [[ $USERNAME =~ '^[A-Za-z_][A-Za-z0-9_-]*$' ]] || return 1
  home=${~:-~$USERNAME}
  if [[ $DF_SECRETS_TEST == 1 && $DF_SECRETS_HOME == (/tmp|/var/tmp|/dev/shm)/* && -f $DF_SECRETS_HOME/.private-test && ! -L $DF_SECRETS_HOME/.private-test ]]; then
    home=$DF_SECRETS_HOME
  fi
  file=$home/.config/secrets/env.sh
  if [[ ! -e $file && ! -L $file ]]; then
    file=$home/dotfiles/env.secret.sh
    [[ -e $file || -L $file ]] || return 0
    legacy=1
  fi
  # The workstation owner already has a managed-home ACL. Trust that one
  # named writer only through the same root-owned anchor used by the publisher.
  if [[ -f $anchor && ! -L $anchor ]]; then
    local anchor_ok=1
    for part in /etc /etc/usr-managed $anchor; do
      zstat -H info -L -- $part 2>/dev/null || { anchor_ok=0; break; }
      (( info[uid] == 0 && !(info[mode] & 8#22) && (info[mode] & 8#170000) != 8#120000 )) || { anchor_ok=0; break; }
    done
    if (( anchor_ok )); then
      name=$(<$anchor)
      if [[ $name =~ '^[a-z_][a-z0-9_-]*$' ]]; then
        publisher=$(/usr/bin/id -u -- $name 2>/dev/null) || publisher=-1
      fi
    fi
  fi
  # Check every ancestor before any source; zstat -L uses lstat.
  part=$file
  while [[ $part != / ]]; do
    zstat -H info -L -- $part 2>/dev/null || { print -u2 'secrets: unsafe file refused'; return 1; }
    (( (info[mode] & 8#170000) != 8#120000 )) || { print -u2 'secrets: unsafe file refused'; return 1; }
    if [[ $part != $file ]]; then
      (( info[uid] == EUID || info[uid] == 0 )) || { print -u2 'secrets: unsafe ancestor refused'; return 1; }
      if [[ ! ( $DF_SECRETS_TEST == 1 && $part == (/tmp|/dev/shm) && $info[uid] == 0 ) ]]; then
        (( !(info[mode] & 8#2) )) || { print -u2 'secrets: unsafe ancestor refused'; return 1; }
        permissions=$(/usr/bin/getfacl -cpnE -- $part 2>/dev/null) || return 1
        mask=rwx
        for line in ${(f)permissions}; do [[ $line == mask::* ]] && mask=${line##*:}; done
        if [[ $mask == *w* ]]; then
          for line in ${(f)permissions}; do
            kind=${line%%:*}; rights=${line##*:}; who=${${line#*:}%%:*}
            [[ ($kind == user || $kind == group) && $rights == *w* ]] || continue
            [[ $kind == user && ( -z $who || $who == $EUID || $who == 0 || $who == $publisher ) ]] && continue
            print -u2 'secrets: unsafe ancestor ACL refused'; return 1
          done
        fi
      fi
    fi
    part=${part:h}
  done
  zstat -H info -L -- $file 2>/dev/null || return 1
  if (( (info[mode] & 8#170000) != 8#100000 || info[uid] != EUID || info[nlink] != 1 || (info[mode] & 8#77) )); then
    print -u2 'secrets: unsafe file refused'; return 1
  fi
  permissions=$(/usr/bin/getfacl -cpnE -- $file 2>/dev/null) || { print -u2 'secrets: unsafe ACL refused'; return 1; }
  for line in ${(f)permissions}; do
    [[ $line == default:* ]] && { print -u2 'secrets: unsafe ACL refused'; return 1; }
    kind=${line%%:*}; rights=${line##*:}; who=${${line#*:}%%:*}
    if [[ ($kind == user || $kind == group) && -n $who && $rights != --- ]]; then
      print -u2 'secrets: unsafe ACL refused'; return 1
    fi
  done
  if (( legacy )) && [[ -z ${_DF_LEGACY_SECRETS_WARNED-} ]]; then
    typeset -g _DF_LEGACY_SECRETS_WARNED=1
    print -u2 'secrets: legacy ~/dotfiles/env.secret.sh is in use; run usr secrets-migrate --self'
  fi
  # Syntax errors and source-side diagnostics can include assignment text.
  source $file >/dev/null 2>/dev/null || { print -u2 'secrets: source failed'; return 1; }
}
_df_source_private_env
