# Per-command hooks (DEV-a), sourced from .zshrc after ~/.zshrc.local so the settings below can be overridden there.
# Interactive shells with a line editor only, never for agents (CLAUDECODE). Nothing here forks at startup, and each command
# costs two pure-zsh hook calls plus ONE background fork (about 0.13 ms), so the prompt never waits for atuin.
#
#   atuin recording   every finished command goes into the local atuin database (Ctrl+R list: history.zsh). The job runs in
#                     the background: `history start` then `history end` with the exact exit status and duration. atuin has no
#                     timestamp option, so the stored time is the FINISH time of the command. Not recorded: a command with a
#                     leading space, a command that holds a literal secret (DF_SECRET_CMD_RE) and a plain assignment (`export X=value`,
#                     a bare `X=value`; the command is an argv of the atuin job, see below). zsh's own ~/.zsh_history
#                     keeps being written (fallback, autosuggestions).
#   long-command toast  a command that ran at least DF_CMD_NOTIFY_MIN seconds (30; 0 = off in this shell) and finished while its
#                     terminal is not in front starts ~/.config/hypr/scripts/cmd-notify.sh (it decides "in front", shows the
#                     toast, a click focuses the terminal and the tmux pane). Never for: ssh logins (SSH_CONNECTION), a command with
#                     a leading space, interactive programs (DF_CMD_NOTIFY_IGNORE: the first word of the alias-expanded line after sudo/doas/env/command/VAR=x and their options). A
#                     secret-looking command is shown as "(command hidden)". Switch: hub row "Long-command notifications"
#                     (state file, live). Override any DF_* value in ~/.zshrc.local.
[[ -o zle && -o interactive && -z $CLAUDECODE ]] || return 0

: ${DF_CMD_NOTIFY_MIN:=30}          # seconds; 0 = off
(( ${+DF_CMD_NOTIFY_IGNORE} )) || DF_CMD_NOTIFY_IGNORE=(nvim vim vi less man ssh tmux lazygit lazydocker htop btop yazi claude codex gemini top watch fzf hub)
# literal secret values in a command line, matched lower-cased; variable references ($TOKEN, $(rbw get x)) do not count
: ${DF_SECRET_CMD_RE:='(pass(word|wd)?|token|secret|api[_-]?key|credential|private[_-]?key)[a-z0-9_]*([[:space:]]*=[[:space:]]*|:)["'\'']?[^$[:space:]"'\'']{4,}|["'\''][a-z0-9_-]*(pass(word|wd)?|token|secret|api[_-]?key|credential)[a-z0-9_-]*[[:space:]]*:[[:space:]]*[^$[:space:]"'\'']{8,}|auth[a-z0-9_]*=["'\'']?[^$[:space:]"'\'']{4,}|sshpass[[:space:]]+-p|authorization:[[:space:]]*(bearer|basic)[[:space:]]+[^$[:space:]]|(ghp|gho|ghs|github_pat|glpat|xox[abps]|sk)[-_][a-z0-9]{12,}|sk-[a-z]+-[a-z0-9_-]{16,}|--(pass(word|wd)?|token|secret|api[_-]?key)[= ][^$[:space:]-][^[:space:]]{3,}|://[^/[:space:]:@]+:[^@/[:space:]$]+@|(^|[^a-z0-9])(mysql[a-z]*|mariadb[a-z-]*)[[:space:]].*[[:space:]]-p[^[:space:]$-]+|login[[:space:]].*[[:space:]]-p[[:space:]]+[^$[:space:]-]|(^|[^a-z0-9])bw[[:space:]]+(unlock|login)([[:space:]]+[^-$[:space:]][^[:space:]]*){1,2}'}

_df_cmd_assign_re='^[[:space:]]*((export|typeset|declare|local|readonly)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^$]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]$]*)$'
_df_cmd_notify=${XDG_CONFIG_HOME:-$HOME/.config}/hypr/scripts/cmd-notify.sh
zmodload zsh/datetime 2>/dev/null
# $1 = the line as typed, $3 = the line as it will run (aliases expanded: `lzd` -> `lazydocker`), used for the ignore list
_df_cmd_preexec() { _df_cmd_line=$1 _df_cmd_exp=${3:-$1} _df_cmd_dir=$PWD _df_cmd_t0=$EPOCHREALTIME }
_df_cmd_precmd() {
  local ec=$? line=$_df_cmd_line exp=$_df_cmd_exp dir=$_df_cmd_dir t0=$_df_cmd_t0
  _df_cmd_line= _df_cmd_exp= _df_cmd_t0=
  [[ -n $line && -n $t0 && $line != [[:space:]]* ]] || return 0
  local -i ms=$(( (EPOCHREALTIME - t0) * 1000 )) secret=0
  [[ ${(L)line} =~ $DF_SECRET_CMD_RE ]] && secret=1
  # atuin takes the command as an ARGUMENT (no stdin or env form exists), so it sits in the world-readable /proc/PID/cmdline of
  # the background job for a few ms. A plain assignment (`export X=literal`, `typeset`, a bare `X=literal`) never had an argv
  # before and is the likeliest place for an unrecognised secret, so it is not recorded at all (a value with `$` is).
  local -i norec=0
  [[ $line =~ $_df_cmd_assign_re ]] && norec=1
  if (( ! secret && ! norec && $+commands[atuin] )); then
    ( trap '' HUP; cd -q -- $dir 2>/dev/null; local id
      id=$(ATUIN_SHELL=zsh atuin history start --hook -- "$line" 2>/dev/null) && [[ -n $id ]] &&
        atuin history end --hook --exit $ec --duration=$(( ms * 1000000 )) -- $id ) &>/dev/null &!
  fi
  (( DF_CMD_NOTIFY_MIN > 0 && ms >= DF_CMD_NOTIFY_MIN * 1000 )) || return 0
  [[ -z $SSH_CONNECTION && -x $_df_cmd_notify ]] || return 0
  local -a w=(${(z)exp}) extra
  # the first real word: skip wrappers and their options (`sudo -E nvim`, `sudo -u root nvim`, `command nvim`, `FOO=1 nvim`)
  while (( $#w )); do
    case $w[1] in
      sudo|doas) shift w; while [[ $w[1] == -* ]]; do [[ $w[1] == -[ugCDhprtURT] ]] && shift w; shift w; done ;;
      env|nice|time|command|builtin|nohup|exec|noglob|*=*|-*) shift w ;;
      *) break ;;
    esac
  done
  (( ${DF_CMD_NOTIFY_IGNORE[(Ie)${w[1]:t}]} )) && return 0
  (( secret )) && extra=(--hidden)
  DF_CMD=$line DF_CMD_DIR=$dir setsid -f $_df_cmd_notify notify --exit $ec --ms $ms --pid $$ $extra &>/dev/null
  return 0
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _df_cmd_preexec
add-zsh-hook precmd _df_cmd_precmd
