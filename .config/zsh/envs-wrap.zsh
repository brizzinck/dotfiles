# Account-local command wrappers. Source after the readonly _ENVS_BIN has been initialized.
# Parsing is all-or-nothing, has no eval/vault call and never exports a secret into this shell.
_df_envs_load_wrappers() {
  emulate -L zsh
  [[ ${_DF_ENVS_WRAPPERS_PID:-} == $$ ]] && return 0
  zmodload zsh/stat || return
  zmodload zsh/parameter || return
  local account_home=${_ENVS_BIN:h:h:h} file name command names rest component walk_path n
  local publisher=-1 anchor_checked=0 anchor=/etc/usr-managed/devtools-owner anchor_path anchor_ok permissions line kind who rights mask
  local owner_acl group_acl other_acl mask_acl acl_ok acl_pattern='^(user|group):([0-9]*):([r-][w-][x-])$'
  local simple_pattern='^(mask|other)::([r-][w-][x-])$'
  local -a rows fields checked acl_entries
  local -A st seen anchor_st
  # Shipped default: local rows may replace this exact command, without granting agent approval.
  rows=('glab'$'\t''/usr/bin/glab'$'\t''GITLAB_TOKEN,GITLAB_HOST')
  file=$account_home/.config/envs/wrap.tsv
  if [[ -e $file || -L $file ]]; then
    walk_path=/
    for component in ${(s:/:)${file:h}}; do
      [[ -n $component ]] || continue
      walk_path=${walk_path%/}/$component
      if [[ -L $walk_path || ! -d $walk_path ]]; then
        print -u2 -- 'envs: unsafe wrapper metadata path; local wrappers refused'
        return 1
      fi
      if [[ $walk_path == $account_home || $walk_path == $account_home/* ]]; then
        if ! zstat -H st -L -- $walk_path 2>/dev/null || (( st[uid] != EUID || (st[mode] & 8#2) != 0 )); then
          print -u2 -- 'envs: unsafe wrapper metadata parent; local wrappers refused'
          return 1
        fi
        if (( st[mode] & 8#20 )); then
          # Managed homes retain their established publisher writer ACL. Only
          # these two ancestors may use it; envs and wrap.tsv stay private.
          if [[ $walk_path != $account_home && $walk_path != $account_home/.config ]]; then
            print -u2 -- 'envs: unsafe wrapper metadata parent; local wrappers refused'
            return 1
          fi
          if (( ! anchor_checked )); then
            anchor_checked=1 anchor_ok=1
            for anchor_path in /etc /etc/usr-managed $anchor; do
              if ! zstat -H anchor_st -L -- $anchor_path 2>/dev/null || (( anchor_st[uid] != 0 || (anchor_st[mode] & 8#22) != 0 )); then
                anchor_ok=0; break
              fi
              if [[ $anchor_path == $anchor ]]; then
                (( (anchor_st[mode] & 8#170000) == 8#100000 && anchor_st[nlink] == 1 && anchor_st[size] > 0 && anchor_st[size] <= 64 )) || anchor_ok=0
              else
                (( (anchor_st[mode] & 8#170000) == 8#40000 )) || anchor_ok=0
              fi
            done
            if (( anchor_ok )); then
              name=$(<$anchor)
              if [[ $name =~ '^[a-z_][a-z0-9_-]*$' ]]; then
                publisher=$(/usr/bin/id -u -- $name 2>/dev/null) || publisher=-1
                [[ $publisher =~ '^(0|[1-9][0-9]{0,9})$' ]] && (( publisher < 4294967295 )) || publisher=-1
              fi
            fi
          fi
          permissions=$(/usr/bin/getfacl -cpnE -- $walk_path 2>/dev/null) || permissions='invalid'
          mask=rwx owner_acl=0 group_acl=0 other_acl=0 mask_acl=0 acl_ok=1
          acl_entries=()
          for line in ${(f)permissions}; do
            [[ -z $line || $line == default:* ]] && continue
            if [[ $line =~ $acl_pattern ]]; then
              kind=$match[1] who=$match[2] rights=$match[3]
              [[ -z $who || $who =~ '^(0|[1-9][0-9]{0,9})$' ]] || { acl_ok=0; break; }
              if [[ -z $who ]]; then
                if [[ $kind == user ]]; then (( owner_acl++ )); else (( group_acl++ )); fi
              fi
              acl_entries+=($kind:$who:$rights)
            elif [[ $line =~ $simple_pattern ]]; then
              if [[ $match[1] == mask ]]; then
                (( mask_acl++ )); mask=$match[2]
              else
                (( other_acl++ )); [[ $match[2] != *w* ]] || acl_ok=0
              fi
            else
              acl_ok=0; break
            fi
          done
          (( owner_acl == 1 && group_acl == 1 && other_acl == 1 && mask_acl <= 1 )) || acl_ok=0
          if [[ $mask == *w* ]]; then
            for line in $acl_entries; do
              kind=${line%%:*} rights=${line##*:} who=${${line#*:}%%:*}
              [[ $rights == *w* ]] || continue
              [[ $kind == user && ( -z $who || $who == $EUID || $who == 0 || $who == $publisher ) ]] && continue
              acl_ok=0; break
            done
          fi
          if (( ! acl_ok )); then
            print -u2 -- 'envs: unsafe wrapper metadata ancestor ACL; local wrappers refused'
            return 1
          fi
        fi
      fi
    done
    if [[ -L $file ]] || ! zstat -H st -- $file 2>/dev/null || (( st[uid] != EUID || (st[mode] & 8#177) != 0 || st[nlink] != 1 || (st[mode] & 8#170000) != 8#100000 || st[size] > 65536 )); then
      print -u2 -- 'envs: unsafe wrapper metadata; local wrappers refused'
      return 1
    fi
    while IFS= read -r rest || [[ -n $rest ]]; do
      [[ -n $rest && $rest != \#* ]] || continue
      fields=(${(ps:\t:)rest})
      if (( ${#fields} != 3 )); then
        print -u2 -- 'envs: invalid wrapper metadata; local wrappers refused'
        return 1
      fi
      name=$fields[1] command=$fields[2] names=$fields[3]
      if [[ ! $name =~ '^[A-Za-z][A-Za-z0-9_-]*$' || $command != /* || ! -x $command || -d $command || -n ${seen[$name]-} || $name == (envs|er|ere|ert) ]] || (( ${+builtins[$name]} )); then
        print -u2 -- 'envs: invalid wrapper command; local wrappers refused'
        return 1
      fi
      if [[ $command == *[$'\x01'-$'\x1f'$'\x7f']* || -z $names || $names == ,* || $names == *, || $names == *,,* ]]; then
        print -u2 -- 'envs: invalid wrapper fields; local wrappers refused'
        return 1
      fi
      for n in ${(s:,:)names}; do
        if [[ ! $n =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]]; then
          print -u2 -- 'envs: invalid wrapper variable; local wrappers refused'
          return 1
        fi
      done
      seen[$name]=1
      checked+=($rest)
    done < $file
    for rest in $checked; do
      fields=(${(ps:\t:)rest})
      if [[ $fields[1] == glab ]]; then rows=(); fi
    done
    rows+=($checked)
  fi
  for rest in $rows; do
    fields=(${(ps:\t:)rest})
    name=$fields[1] command=$fields[2] names=$fields[3]
    (( ${+aliases[$name]} )) && unalias -- $name
    functions[$name]='$_ENVS_BIN run -g --only '${(q)names}' -- '${(q)command}' "$@"'
  done
  typeset -g _DF_ENVS_WRAPPERS_PID=$$
}
_df_envs_load_wrappers
