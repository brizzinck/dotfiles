# Prompt marker for `envs` (DEV-b), sourced from .zshrc after the PROMPT block. Pure zsh, no fork: in a directory below a
# .envs.toml whose project uses a NON-default environment (`envs use stage`) the prompt shows [stage] (yellow) or, for a
# protected one, a bold red [prod]. Nothing else: no value, no name of a secret. The state is ~/.local/state/envs/active.tsv
# (ROOT, ENV, UNTIL epoch or 0, KIND p|-); the file is read again only when its mtime changed or a selection expired.
zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload zsh/datetime 2>/dev/null
typeset -g _ENVS_PROMPT='' _ENVS_ROOT='' _ENVS_MT=-1 _ENVS_UNTIL=0
_ENVS_FILE=${XDG_STATE_HOME:-$HOME/.local/state}/envs/active.tsv

_envs_chpwd() {
  local d=$PWD
  _ENVS_ROOT=''
  while [[ $d != / ]]; do
    [[ -f $d/.envs.toml ]] && { _ENVS_ROOT=${d:A}; break }
    d=${d:h}
  done
  _ENVS_MT=-1
  _envs_precmd
}

_envs_precmd() {
  if [[ -z $_ENVS_ROOT ]]; then _ENVS_PROMPT=''; return 0; fi
  local -a mt
  zstat -A mt +mtime -- $_ENVS_FILE 2>/dev/null || mt=(0)
  (( mt[1] == _ENVS_MT && (_ENVS_UNTIL == 0 || _ENVS_UNTIL > EPOCHSECONDS) )) && return 0
  _ENVS_MT=$mt[1] _ENVS_UNTIL=0 _ENVS_PROMPT=''
  [[ -r $_ENVS_FILE ]] || return 0
  local line until
  local -a f
  for line in "${(@f)$(<$_ENVS_FILE)}"; do
    f=("${(@ps:\t:)line}")
    [[ $f[1] == $_ENVS_ROOT ]] || continue
    until=${f[3]:-0}
    (( until == 0 || until > EPOCHSECONDS )) || continue
    (( until )) && _ENVS_UNTIL=$until
    if [[ $f[4] == p ]]; then _ENVS_PROMPT="%F{1}%B[${f[2]}]%b%f "; else _ENVS_PROMPT="%F{3}[${f[2]}]%f "; fi
    break
  done
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _envs_chpwd
add-zsh-hook precmd _envs_precmd
_envs_chpwd
