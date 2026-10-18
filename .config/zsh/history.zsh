# Ctrl+R over the local atuin database (DEV-a), on the shared modal fzf list. Sourced from .zshrc after vi-mode.zsh and
# cmd-hooks.zsh (which records every command into atuin). No `atuin init`: no extra widgets, no Up-arrow/`k`/`/` rebinding,
# no Atuin AI `?`, no autosuggestion strategy override. Without atuin or its database the old zsh-history widget stays.
#
#   Ctrl+R               [I] history> list of every command of every terminal (newest first), Enter puts it on the line
#   Tab / Shift+Tab      next / previous filter: global -> workspace (git repository) -> directory -> session
#   NORMAL l / h         the same (Esc first), ua/ru twins come with the library; the header shows the filter
# Only for interactive shells with a line editor and never for agent shells.
[[ -o zle && -o interactive && -z $CLAUDECODE ]] || return 0
(( $+commands[atuin] )) || return 0

# a fresh id per interactive shell, never inherited: a tmux pane would otherwise share the id of the tmux server's shell
ATUIN_SESSION=${$(</proc/sys/kernel/random/uuid)//-}
export ATUIN_SESSION

_df_atuin_db=${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db
_df_atuin_sh=${XDG_CONFIG_HOME:-$HOME/.config}/fzf/atuin-history.sh

# first interactive shell without a database: import ~/.zsh_history once, in the background, under a lock
if [[ ! -e $_df_atuin_db ]] && (( $+commands[flock] )); then
  {
    mkdir -p ${XDG_STATE_HOME:-$HOME/.local/state}
    flock -n 9 && [[ ! -e $_df_atuin_db ]] && HISTFILE=${HISTFILE:-$HOME/.zsh_history} atuin import zsh
  } 9>${XDG_STATE_HOME:-$HOME/.local/state}/atuin-import.lock &>/dev/null &!
fi

_df_atuin_history_widget() {
  emulate -L zsh
  setopt localoptions noglobsubst no_aliases no_glob pipefail
  local state=${XDG_RUNTIME_DIR:-/tmp}/atuin-fzf.$$ sel rec i
  local -a vf
  (( $#_df_vf_opts[atuin] )) || _df_vf_load 2>/dev/null
  (( $#_df_vf_opts[atuin] )) && vf=("${(@Q)${(z)_df_vf_opts[atuin]}}")
  print -r -- global >| $state
  sel=$(DF_ATUIN_STATE=$state VF_ACT_NORMAL=$_df_vf_act[atuin] SHELL=/bin/bash \
    $_df_atuin_sh rows 2>/dev/null | DF_ATUIN_STATE=$state VF_ACT_NORMAL=$_df_vf_act[atuin] SHELL=/bin/bash \
    fzf --read0 --print0 --scheme=history --delimiter='\t' --with-nth=5.. --no-multi-line --height=40% \
      --query="$LBUFFER" --header "$($_df_atuin_sh header)" \
      --bind "tab:transform($_df_atuin_sh cycle +1)" --bind "btab:transform($_df_atuin_sh cycle -1)" \
      --preview "$_df_atuin_sh preview {f}" --preview-window=down,4,wrap "${vf[@]}")
  local ret=$?
  command rm -f -- $state
  if [[ -n $sel ]]; then
    rec=$sel
    for i in 1 2 3 4; do rec=${rec#*$'\t'}; done
    BUFFER=${rec%$'\0'}
    CURSOR=$#BUFFER
  fi
  zle reset-prompt
  return $ret
}

# keep the widget name: fzf's binds, the vi-mode twins and the keymap collector all refer to it
if (( $+functions[_df_fzf_history_orig] )); then
  fzf-history-widget() {
    if [[ -r $_df_atuin_db ]]; then
      _df_atuin_history_widget "$@"
    else
      _df_vf_run history FZF_CTRL_R_OPTS _df_fzf_history_orig "$@"
    fi
  }
fi
