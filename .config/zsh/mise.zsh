# mise (DEV-b), sourced from .zshrc after the last PATH change; replaces direnv. Returns at once when mise is missing.
#   DF_MISE_MODE (never a MISE_* name: mise reads those as settings; set it in ~/.zshrc.local):
#     activate  (default for humans) mise's hook runs at every prompt and every cd
#     chpwd     the hook runs on cd only (cheaper prompt; the env is refreshed when you change directory)
#     shims     PATH shims only, no hook (default for agent and non-tty shells: a snapshot never runs precmd, so `activate`
#               would freeze a stale PATH)
#   DF_MISE_AUTOINSTALL=0 turns off the install-on-cd below.
(( $+commands[mise] )) || return 0
typeset _m=${DF_MISE_MODE:-}
if [[ -z $_m ]]; then
  if [[ -n $CLAUDECODE || ! -t 0 || ! -o interactive ]]; then _m=shims; else _m=activate; fi
fi
case $_m in activate|chpwd|shims) ;; *) _m=activate ;; esac

if [[ $_m == shims ]]; then
  path=(${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims $path)
  unset _m; return 0
fi

# `mise activate zsh` costs a fork per shell: cache it, regenerate when the mise binary or this file is newer
typeset _c=${XDG_CACHE_HOME:-$HOME/.cache}/zsh/mise-activate.zsh
if [[ ! -s $_c || $commands[mise] -nt $_c || ${(%):-%x} -nt $_c ]]; then
  mkdir -p ${_c:h} 2>/dev/null
  if command mise activate zsh >| $_c.$$ 2>/dev/null && [[ -s $_c.$$ ]]; then mv -f $_c.$$ $_c; else rm -f $_c.$$; fi
fi
[[ -s $_c ]] || { unset _m _c; return 0 }
source $_c
# chpwd mode: keep the cd hook, drop the per-prompt one (mise's hook functions are named _mise_hook*)
[[ $_m == chpwd ]] && precmd_functions=(${precmd_functions:#_mise_hook*})

# Completion needs the `usage` package; written once, picked up by the next shell (the site-functions dir is in fpath)
if (( $+commands[usage] )); then
  typeset _f=${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions/_mise
  if [[ ! -s $_f || $commands[mise] -nt $_f ]]; then
    mkdir -p ${_f:h} 2>/dev/null
    command mise completion zsh >| $_f.$$ 2>/dev/null && [[ -s $_f.$$ ]] && mv -f $_f.$$ $_f || rm -f $_f.$$
  fi
fi

# Install on cd: a new or changed mise config in this directory tree -> missing tools are installed in the background, only
# for a config mise already trusts (an untrusted one makes the query fail: nothing is installed). The next prompt prints one
# line and refreshes the env. Humans only (interactive tty shells reach this point).
[[ ${DF_MISE_AUTOINSTALL:-1} == 0 ]] && { unset _m _c _f; return 0; }
zmodload -F zsh/stat b:zstat 2>/dev/null
typeset -gA _df_mise_seen
_df_mise_dir=${XDG_RUNTIME_DIR:-/tmp}/mise-auto
_df_mise_chpwd() {
  local d=$PWD f key out
  while [[ $d != / ]]; do
    for f in mise.toml .mise.toml mise/config.toml .config/mise.toml .tool-versions .nvmrc .node-version .python-version; do
      [[ -f $d/$f ]] && break 2
    done
    [[ $d == $HOME ]] && return 0
    d=${d:h}
  done
  [[ -f $d/$f ]] || return 0
  zstat -A key +mtime -- $d/$f 2>/dev/null || return 0
  key=$d/$f:$key
  [[ -n ${_df_mise_seen[$key]} ]] && return 0
  _df_mise_seen[$key]=1
  out=$(command mise ls --current --missing 2>/dev/null) || return 0
  [[ -n $out ]] || return 0
  mkdir -p -m 700 $_df_mise_dir 2>/dev/null
  rm -f $_df_mise_dir/done
  ( command mise install >| $_df_mise_dir/log 2>&1; print $? >| $_df_mise_dir/done ) &!
  print -r -- "mise: installing missing tools in the background (log: $_df_mise_dir/log)"
}
_df_mise_precmd() {
  [[ -e $_df_mise_dir/done ]] || return 0
  local rc; rc=$(<$_df_mise_dir/done); rm -f $_df_mise_dir/done
  if [[ $rc == 0 ]]; then print -r -- "mise: tools installed"; else print -r -- "mise install failed: $_df_mise_dir/log"; fi
  (( $+functions[_mise_hook] )) && _mise_hook
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _df_mise_chpwd
add-zsh-hook precmd _df_mise_precmd
_df_mise_chpwd   # the directory the shell starts in
unset _m _c _f
