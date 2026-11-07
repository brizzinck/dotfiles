# skw: agents mark sessions before the daemon creates windows (docs/agents/skw-windows.md).
# Source from .zshenv and after mise; prepend again on prompt/cd when mise refreshes PATH.
_df_skw_path() {
  local shim=$HOME/.local/lib/skw-shim
  [[ -x $shim/skw ]] || return 0
  path=("$shim" "${(@)path:#$shim}")
  export PATH
}
_df_skw_path
if [[ -o interactive ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _df_skw_path
  add-zsh-hook chpwd _df_skw_path
fi
