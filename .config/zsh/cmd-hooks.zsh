# Per-command hooks (DEV-a), sourced from .zshrc after ~/.zshrc.local so the settings below can be overridden there.
# Interactive shells with a line editor only, never for agents (CLAUDECODE). Nothing here forks at startup, and each command
# costs two pure-zsh hook calls plus ONE background fork (about 0.13 ms), so the prompt never waits for atuin.
#
#   atuin recording   every finished command goes into the local atuin database (Ctrl+R list: history.zsh). The job runs in
#                     the background: `history start` then `history end` with the exact exit status and duration. atuin has no
#                     timestamp option, so the stored time is the FINISH time of the command. Not recorded: a command with a
#                     leading space and a command that holds a literal secret (DF_SECRET_CMD_RE). zsh's own ~/.zsh_history
#                     keeps being written (fallback, autosuggestions).
[[ -o zle && -o interactive && -z $CLAUDECODE ]] || return 0

# literal secret values in a command line, matched lower-cased; variable references ($TOKEN, $(rbw get x)) do not count
: ${DF_SECRET_CMD_RE:='(pass(word|wd)?|token|secret|api[_-]?key|credential|private[_-]?key)[a-z0-9_]*[[:space:]]*[=:][[:space:]]*["'\'']?[^$[:space:]"'\'']{4,}|auth[a-z0-9_]*=["'\'']?[^$[:space:]"'\'']{4,}|sshpass[[:space:]]+-p|authorization:[[:space:]]*(bearer|basic)[[:space:]]+[^$[:space:]]|(ghp|gho|ghs|github_pat|glpat|xox[abps]|sk)[-_][a-z0-9]{12,}|--(pass(word|wd)?|token|secret|api[_-]?key)[= ][^$[:space:]-][^[:space:]]{3,}'}

zmodload zsh/datetime 2>/dev/null
_df_cmd_preexec() { _df_cmd_line=$1 _df_cmd_dir=$PWD _df_cmd_t0=$EPOCHREALTIME }
_df_cmd_precmd() {
  local ec=$? line=$_df_cmd_line dir=$_df_cmd_dir t0=$_df_cmd_t0
  _df_cmd_line= _df_cmd_t0=
  [[ -n $line && -n $t0 && $line != [[:space:]]* ]] || return 0
  local -i ms=$(( (EPOCHREALTIME - t0) * 1000 )) secret=0
  [[ ${(L)line} =~ $DF_SECRET_CMD_RE ]] && secret=1
  if (( ! secret && $+commands[atuin] )); then
    ( trap '' HUP; cd -q -- $dir 2>/dev/null; local id
      id=$(ATUIN_SHELL=zsh atuin history start --hook -- "$line" 2>/dev/null) && [[ -n $id ]] &&
        atuin history end --hook --exit $ec --duration=$(( ms * 1000000 )) -- $id ) &>/dev/null &!
  fi
  return 0
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _df_cmd_preexec
add-zsh-hook precmd _df_cmd_precmd
