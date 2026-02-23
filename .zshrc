export USER=$(whoami)
export HOME="/home/$USER"

export WGPU_BACKEND=vulkan

export FPCDIR="/usr/lib/fpc/3.2.2"
export PP="/usr/lib/fpc/3.2.2/ppcx64"
export LAZARUSDIR="/usr/lib/lazarus"   
export FPCTARGET="x86_64-linux"
export FPCTARGETCPU="x86_64"

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

export CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192

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
export TERMINAL="ghostty"
export BROWSER="flatpak run app.zen_browser.zen"

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

[ -f "$HOME/dotfiles/env.secret.sh" ] && source "$HOME/dotfiles/env.secret.sh"

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  

[ -s "/home/$USER/.bun/_bun" ] && source "/home/$USER/.bun/_bun"

wmctrl -r ":ACTIVE:" -b add,maximized_vert,maximized_horz

alias firefox="firefox --start-maximized"

alias q="exit"
alias v="nvim"
alias vi="nvim"
alias vim="nvim"
alias c="clear"

alias gtj="cd $HOME/job && clear && ls -a"
alias gtd="cd $HOME/dotfiles"
alias gtn="cd $HOME/dotfiles/.config/nvim"
alias gtc="cd $HOME/.config"
alias gto="cd $HOME/job/obsidian"

alias gtjr="cd $HOME/job/rust && clear && ls -a"
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

alias ig="lazygit"

alias id="lazydocker"

alias rr="cargo r"
alias rc="cargo clippy"
alias rf="cargo fmt"
alias rt="cargo t"
alias rb="cargo b"
of() {
  EDITION=$(grep '^edition' rustfmt.toml | cut -d'"' -f2)
  find . -name "*.rs" | while read -r file; do
    rustup run nightly-2025-04-02 orustfmt --edition="$EDITION" --emit=stdout < "$file" > "$file.formatted"
    mv "$file.formatted" "$file"
  done
}

rg() {
  if [ -f "./main.go" ]; then 
    go run .
  elif [ -f "./cmd/main.go" ]; then
    go run ./cmd/main.go
  elif [ -f "./cmd/api/main.go" ]; then
    go run ./cmd/api/main.go
  fi
}

alias rg="rg"
alias lg="golangci-lint run --fix; go mod tidy"
alias lgr='find . -name "go.mod" -execdir sh -c "golangci-lint run --fix; go mod tidy" \;'
alias tg="go test ./..."

alias lf="facad"

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

center_text "┌─┐┬┌─┌─┐┬  ┌─┐┌─┐"
center_text "└─┐├┴┐├─┤│  └─┐├┤ "
center_text "└─┘┴ ┴┴ ┴┴─┘└─┘└─┘"

echo -e "\e[0m" 

source "$ZSH/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
