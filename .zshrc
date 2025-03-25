export HOME="/home/skalse"

export WGPU_BACKEND=vulkan

export ANDROID_HOME="$HOME/Android/Sdk"     
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/25.2.9519653"
export NDK_HOME="$ANDROID_NDK_ROOT"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
export JAVA_HOME="/usr/lib/jvm/default"

export ZSH="$HOME/.oh-my-zsh"

export PATH="$PATH:$HOME/go/bin"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.bun/bin:$PATH"
export PATH="$HOME/.npm/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"
export PATH="$HOME/.local/share/npm/bin:$PATH"
export PATH="$HOME/.local/share/cargo/bin:$PATH"
export PATH="$HOME/.local/share/go/bin:$PATH"
export PATH="$HOME/.local/share/rustup/bin:$PATH"

ZSH_THEME="robbyrussell"

plugins=(
  git
  web-search
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

export EDITOR="nvim"
export GIT_EDITOR="nvim"
export VISUAL="nvim"
export TERMINAL="alacritty"
export BROWSER="firefox-developer-edition"

export MOZ_ENABLE_WAYLAND=1
export MOZ_GTK_TITLEBAR_DECORATION=client
export QT_SCALE_FACTOR=1.5
export XCURSOR_SIZE=32
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  

[ -s "/home/skalse/.bun/_bun" ] && source "/home/skalse/.bun/_bun"

wmctrl -r ":ACTIVE:" -b add,maximized_vert,maximized_horz

alias firefox="firefox-developer-edition --start-maximized"

alias q="exit"
alias v="nvim"
alias vi="nvim"
alias vim="nvim"
alias c="clear"

alias gtj="cd $HOME/job && clear && ls -a"
alias gtd="cd $HOME/dotfiles"
alias gtc="cd $HOME/.config"

alias gtjr="td $HOME/job/rust && clear && ls -a"
alias gtjg="cd $HOME/job/go && clear && ls -a"

alias g="git"
alias gs="git status"
alias ga="git add"
alias gc="git commit"
alias gcm="git commit -m"
alias gcb="git checkout -b"
alias gco="git checkout"
alias gpl="git pull"
alias gps="git push"
alias gcl="git clone"
alias gbd="git branch -D"
alias gbs="git switch"

alias rr="cargo r"
alias rc="cargo clippy"
alias rf="cargo fmt"
alias rt="cargo t"
alias rb="cargo b"

alias rg="go run ."
alias lg="golangci-lint run ./... && go mod tidy"
alias tg="go test ./..."

eval "$(zoxide init zsh)"

alias f="$HOME/.local/bin/fzfman.sh"
alias cht="$HOME/.local/bin/chtman.sh"

center_text() {
  local text="$1"
  local columns=$(tput cols) 
  local text_length=${#text}
  local padding=$(( (columns - text_length) / 2 ))

  if [ "$padding" -gt 0 ]; then
    printf "%*s%s\n" "$padding" "" "$text"
  else
    echo "$text"
  fi
}
echo -e "\e[32m" 

center_text "███████╗██╗  ██╗ █████╗ ██╗     ███████╗███████╗"
center_text "██╔════╝██║ ██╔╝██╔══██╗██║     ██╔════╝██╔════╝"
center_text "███████╗█████╔╝ ███████║██║     ███████╗█████╗  "
center_text "╚════██║██╔═██╗ ██╔══██║██║     ╚════██║██╔══╝  "
center_text "███████║██║  ██╗██║  ██║███████╗███████║███████╗"
center_text "╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝"

echo -e "\e[0m" 

source "$ZSH/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
