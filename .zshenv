# Cargo's installer used this before .zshenv was stowed; keep its setup.
[[ -r $HOME/.cargo/env ]] && source "$HOME/.cargo/env"
[[ -d $HOME/.local/bin ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/skw-shim.zsh ]] && source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/skw-shim.zsh"
