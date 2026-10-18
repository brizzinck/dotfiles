# Completion extras (DEV-a), sourced from .zshrc after oh-my-zsh (compinit and fzf-tab are loaded). Interactive shells with a
# line editor only, never for agents (CLAUDECODE).
#
#   carapace   fills the gaps ONLY: `compdef _df_carapace_default -default-` is used for commands without a zsh completion
#              (lazygit, glab, k9s, hurl, tailscale, atuin, ...). The first Tab on such a command loads a cached script
#              (~/.cache/zsh/carapace.zsh, rebuilt when the carapace binary is newer) and calls carapace's completer when it
#              knows the command, else zsh's `_default` (files). The native zsh completions (git, docker, systemctl,
#              pacman, ssh, ...) are never overridden, startup cost is a few assignments (`source <(carapace _carapace zsh)`
#              would replace ~1000 of them and cost ~4 ms per shell). No bridges (they spawn other shells), no spec shims.
#   fzf-tab    the completion menu looks and behaves like every other menu (vimfzf): [I] typing filters, Esc = [N] with
#              j k g G v / i a q (ua/ru twins), Ctrl+j/k/d/u, Tab / Shift+Tab move, Ctrl+L accepts and continues (into a
#              directory), F1 / F2 switch the group, Enter accepts. Groups get a header, the menu is always the list.
(( $+functions[compdef] )) || return 0
[[ -o zle && -o interactive && -z $CLAUDECODE ]] || return 0

if (( $+commands[carapace] )); then
  _df_cara_cache=${XDG_CACHE_HOME:-$HOME/.cache}/zsh/carapace.zsh
  # the completer function + a lookup table of the commands carapace knows (no compdef, no PATH line)
  _df_cara_load() {
    emulate -L zsh
    local c=$_df_cara_cache
    if [[ ! -s $c || $commands[carapace] -nt $c ]]; then
      mkdir -p ${c:h} || return 1
      carapace _carapace zsh 2>/dev/null | awk '
        /^export PATH=/ { next }
        /^compdef _carapace_completer / { sub(/^compdef _carapace_completer /, ""); gsub(/"/, "")
          n = split($0, a, " "); printf "typeset -gA _df_cara_cmds=("; for (i = 1; i <= n; i++) printf " %c%s%c 1", 39, a[i], 39; print " )"; next }
        { print }' >| $c.$$ && [[ -s $c.$$ ]] && mv -f $c.$$ $c || { rm -f $c.$$; return 1 }
    fi
    source $c
  }
  _df_carapace_default() {
    (( ${+_df_cara_cmds} )) || _df_cara_load 2>/dev/null
    if (( ${+_df_cara_cmds[${words[1]:t}]} && $+functions[_carapace_completer] )); then _carapace_completer "$@"; else _default "$@"; fi
  }
  compdef _df_carapace_default -default-
fi

zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' menu no
# fzf-tab: the modal options of vi-mode.zsh (label `complete`), evaluated per completion so there is no startup cost
zstyle -e ':fzf-tab:*' fzf-flags '(( $#_df_vf_opts[complete] )) || _df_vf_load 2>/dev/null; reply=("${(@Q)${(z)_df_vf_opts[complete]}}")'
_df_ftb_fzf() { VF_ACT_NORMAL=$_df_vf_act[complete] fzf "$@" }
zstyle ':fzf-tab:*' fzf-command _df_ftb_fzf
zstyle ':fzf-tab:*' continuous-trigger ctrl-l
(( $+commands[eza] )) && zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always --group-directories-first $realpath'
