# Account-local command wrappers. Source after the readonly _ENVS_BIN has been initialized.
# Parsing is all-or-nothing, has no eval/vault call and never exports a secret into this shell.
_df_envs_load_wrappers() {
  emulate -L zsh
  [[ ${_DF_ENVS_WRAPPERS_PID:-} == $$ ]] && return 0
  zmodload zsh/stat || return
  zmodload zsh/parameter || return
  local account_home=${_ENVS_BIN:h:h:h} file name command names rest component walk_path n
  local -a rows fields checked
  local -A st seen
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
        if ! zstat -H st -- $walk_path 2>/dev/null || (( st[uid] != EUID || (st[mode] & 8#22) != 0 )); then
          print -u2 -- 'envs: unsafe wrapper metadata parent; local wrappers refused'
          return 1
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
