# zsh vi-mode glue (V1c). Sourced from .zshrc right after oh-my-zsh, which loads the `vi-mode` plugin
# (cursor shape, `bindkey -v`, clipboard-aware yank/put). Only for interactive shells with a line editor.
#
#   Esc / Ctrl+[   NORMAL            i a I A o O      back to INSERT        v   edit the line in nvim ($VISUAL)
#   cursor         beam = INSERT, block = NORMAL, underline-ish block = VISUAL (DECSCUSR, ghostty and tmux pass it)
#   RPROMPT        [I] muted, [N] yellow, [V] purple (ANSI indices, so both theme variants follow)
#   Ctrl+V / V     visual / visual-line (char visual moved from v: v is readline's "edit in $EDITOR", and a two-key
#                  `vv` cannot be typed within KEYTIMEOUT=1)
#   INSERT keeps readline basics: Ctrl+A/E/B/F/K/U/W/H/P/N/L/R, Ctrl+Y accepts the autosuggestion (Ctrl+Space is
#   the tmux prefix)
#   sudo-command-line: NORMAL `gs` (g-prefix like ga/gg/gu: Esc gs, then back with i/A) and Ctrl+X s in INSERT/emacs.
#   Hyprland grabs Alt+S (screenshot), so the old Alt+s never reached the shell; S stays vi's substitute-line, and the
#   sudo plugin's Esc-Esc cannot work with a 10 ms KEYTIMEOUT. Ctrl+X s has ua/ru twins (Ctrl+X ы / і), gs too.
#   ua/ru layouts: every NORMAL/operator/visual key has a Cyrillic twin from the physical-key map (layout-keys.zsh)
#   Ctrl+R / Ctrl+T / Alt+C: the same fzf widgets on the shared modal look (INSERT/NORMAL, [I]/[N] in the prompt)
[[ -o zle && -o interactive ]] || return 0

# ── keymaps ──────────────────────────────────────────────────────────────────
bindkey -M viins '^A' beginning-of-line '^E' end-of-line '^B' backward-char '^F' forward-char
bindkey -M viins '^K' kill-line '^U' backward-kill-line '^W' backward-kill-word '^H' backward-delete-char
bindkey -M viins '^?' backward-delete-char '^L' clear-screen
bindkey -M viins '^Y' autosuggest-accept
bindkey -M vicmd '^Y' autosuggest-accept

# `v` edits the whole line in nvim (readline vi-mode convention); the plugin's two-key `vv` is unreachable at 10 ms
bindkey -M vicmd -r vv
bindkey -M vicmd 'v' edit-command-line
bindkey -M vicmd '^V' visual-mode

# sudo plugin: Esc-Esc is ambiguous with Esc -> NORMAL; `gs` (NORMAL) and Ctrl+X s (INSERT, emacs) instead.
# Not Alt+s: Hyprland's ALT+S (screenshot) grabs it before any terminal sees it. `gs` is a free vicmd g-key
# (ga ge gE gg gu gU g~ are taken); the ua/ru twin of `gs` comes from _df_dup_pairs below, the one of Ctrl+X s here.
bindkey -M emacs -r '\e\e'; bindkey -M viins -r '\e\e'; bindkey -M vicmd -r '\e\e'
bindkey -M emacs '^Xs' sudo-command-line
bindkey -M viins '^Xs' sudo-command-line
bindkey -M vicmd 'gs' sudo-command-line
if (( ${+LAYOUT_US_OF} )); then
  for _df_c _df_u in "${(@kv)LAYOUT_US_OF}"; do
    [[ $_df_u == s ]] || continue
    bindkey -M emacs "^X$_df_c" sudo-command-line
    bindkey -M viins "^X$_df_c" sudo-command-line
  done
  unset _df_c _df_u
fi

# ── mode indicator (RPROMPT) ─────────────────────────────────────────────────
# zsh keeps $KEYMAP=vicmd while a visual selection is active, so [V] comes from REGION_ACTIVE; a line-pre-redraw hook
# repaints the prompt (and the cursor) when the state changes, which zle-keymap-select does not cover for visual mode.
vi_mode_prompt_info() {
  case ${VI_KEYMAP:-main} in
    visual)        print -rn -- '%B%F{5}[V]%f%b' ;;
    vicmd | viopp) print -rn -- '%B%F{3}[N]%f%b' ;;
    *)             print -rn -- '%F{8}[I]%f' ;;
  esac
}
RPROMPT='$(vi_mode_prompt_info)'
_df_vi_state=''
_df_vi_redraw() {
  local st=$KEYMAP:${REGION_ACTIVE:-0}
  [[ $st == $_df_vi_state ]] && return 0
  _df_vi_state=$st
  if [[ $KEYMAP == vicmd && ${REGION_ACTIVE:-0} != 0 ]]; then VI_KEYMAP=visual; else VI_KEYMAP=$KEYMAP; fi
  _vi-mode-set-cursor-shape-for-keymap $VI_KEYMAP 2>/dev/null
  zle .reset-prompt
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-pre-redraw _df_vi_redraw

# ── ua/ru: Cyrillic twins for NORMAL, operator-pending and visual keys ──────────────────────────────────────
# layout_dup_keys covers the single keys (h j k l w b e dd ...). Two-key sequences (iw aw gg gu ...) get every
# twin combination here; both keys must be Cyrillic, one layout is active for the whole sequence.
_df_dup_pairs() {
  emulate -L zsh
  local km line seq a b ca cb
  local -A cur rev
  for ca cb in "${(@kv)LAYOUT_US_OF}"; do rev[$cb]+="$ca "; done
  for km in "$@"; do
    cur=()
    for line in "${(@f)$(bindkey -M $km 2>/dev/null)}"; do
      [[ $line =~ '^"([a-zA-Z])([a-zA-Z])" ([^ ]+)$' ]] && cur[$match[1]$match[2]]=$match[3]
    done
    for seq in ${(k)cur}; do
      [[ ${cur[$seq]} == undefined-key || ${cur[$seq]} == \"* ]] && continue
      a=${seq[1]} b=${seq[2]}
      for ca in ${=rev[$a]-}; do
        for cb in ${=rev[$b]-}; do bindkey -M $km "$ca$cb" "${cur[$seq]}"; done
      done
    done
  done
}
if (( ${+LAYOUT_US_OF} )); then
  layout_dup_keys vicmd viopp visual
  _df_dup_pairs vicmd viopp visual
  layout_dup_meta viins vicmd
fi

# ── fzf widgets (Ctrl+R history, Ctrl+T files, Alt+C directories) on the shared modal list ───────────────────
# The look and keys are generated by ~/.config/fzf/vimfzf.sh (VF_PRINT) per widget label, cached in
# ~/.cache/vimfzf/zsh-widgets.zsh and refreshed when vimfzf.sh or the layout table is newer. The widgets keep
# fzf's inline 40% height (the library's --height=100% is dropped).
typeset -gA _df_vf_opts _df_vf_act
_df_vf_load() {
  emulate -L zsh
  local cfg=${XDG_CONFIG_HOME:-$HOME/.config} cache=${XDG_CACHE_HOME:-$HOME/.cache}/vimfzf/zsh-widgets.zsh
  local lib=$cfg/fzf/vimfzf.sh label out a
  local -a lines args
  [[ -r $lib ]] || return 1
  if [[ ! -s $cache || $lib -nt $cache || $cfg/layout/layout-keys.sh -nt $cache || $cfg/zsh/vi-mode.zsh -nt $cache ]]; then
    mkdir -p ${cache:h} || return 1
    {
      # atuin = Ctrl+R over the atuin database (history.zsh): NORMAL l / h cycle the filter like Tab / Shift+Tab;
      # complete = the fzf-tab completion menu (completion.zsh)
      for label in history files cd atuin complete; do
        args=()
        [[ $label == atuin ]] && args=("l:transform($cfg/fzf/atuin-history.sh cycle +1)" "h:transform($cfg/fzf/atuin-history.sh cycle -1)")
        out=$(bash -c '. "$1"; VF_NORMAL_BINDS=("${@:3}"); VF_PROMPT=${2/atuin/history} VF_PRINT=1 vimfzf; printf "%s\n" "$VF_ACT_NORMAL"' _ "$lib" "$label" "${args[@]}" 2>/dev/null) || return 1
        lines=("${(@f)out}")
        print -r -- "_df_vf_act[$label]=${(qq)lines[-1]}"
        lines[-1]=()
        args=()
        for a in "${lines[@]}"; do [[ $a == --height* ]] || args+=("${(qq)a}"); done
        print -r -- "_df_vf_opts[$label]=${(qq)${(j: :)args}}"
      done
    } >$cache.$$ && mv -f $cache.$$ $cache || { rm -f $cache.$$; return 1 }
  fi
  source $cache
}

# _df_vf_run LABEL OPTS-VARIABLE ORIGINAL-FUNCTION: run fzf's widget with the modal options for this call only
_df_vf_run() {
  local label=$1 optvar=$2 orig=$3
  (( $#_df_vf_opts[$label] )) || _df_vf_load 2>/dev/null
  if (( $#_df_vf_opts[$label] )); then
    local -x VF_ACT_NORMAL=$_df_vf_act[$label]
    local -x SHELL=/bin/bash          # the modal's transform snippets are POSIX sh, not zsh (echo escapes)
    typeset "$optvar=${(P)optvar-} $_df_vf_opts[$label]"
  fi
  $orig "$@[4,-1]"
}

if (( $+functions[fzf-history-widget] && $+functions[fzf-file-widget] && $+functions[fzf-cd-widget] )); then
  functions[_df_fzf_history_orig]=$functions[fzf-history-widget]
  functions[_df_fzf_file_orig]=$functions[fzf-file-widget]
  functions[_df_fzf_cd_orig]=$functions[fzf-cd-widget]
  fzf-history-widget() { _df_vf_run history FZF_CTRL_R_OPTS _df_fzf_history_orig "$@" }
  fzf-file-widget()    { _df_vf_run files FZF_CTRL_T_OPTS _df_fzf_file_orig "$@" }
  fzf-cd-widget()      { _df_vf_run cd FZF_ALT_C_OPTS _df_fzf_cd_orig "$@" }
fi
