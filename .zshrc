export USER="${USER:-$(whoami)}"

export WGPU_BACKEND=vulkan

if [[ -d /usr/lib/fpc/3.2.2 ]]; then
  export FPCDIR="/usr/lib/fpc/3.2.2"
  export PP="/usr/lib/fpc/3.2.2/ppcx64"
  export LAZARUSDIR="/usr/lib/lazarus"
  export FPCTARGET="x86_64-linux"
  export FPCTARGETCPU="x86_64"
fi

if [[ -d "$HOME/Android/Sdk" ]]; then
  export ANDROID_HOME="$HOME/Android/Sdk"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/25.2.9519653"
  export NDK_HOME="$ANDROID_NDK_ROOT"
  export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
fi
export JAVA_HOME="/usr/lib/jvm/default"

export ZSH="$HOME/.oh-my-zsh"

export PATH="$PATH:$HOME/go/bin"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"

export CLAUDE_CODE_MAX_OUTPUT_TOKENS=66384

ZSH_THEME="robbyrussell"

# fzf-tab must load before the plugins that wrap widgets (autosuggestions, syntax-highlighting last)
plugins=(
  git
  web-search
  sudo
  extract
  copypath
  docker
  golang
  fzf-tab
  zsh-autosuggestions
  zsh-syntax-highlighting
)

ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'   # ANSI 8 = #6b7770 in the everforest-black palette

source $ZSH/oh-my-zsh.sh

# ── History ─────────────────────────────────────────────────────────────────
HISTSIZE=200000
SAVEHIST=200000
setopt HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS

# ── fzf: Ctrl-R history, Ctrl-T files, Alt-C dirs (fd/bat only when installed) ──
if (( $+commands[fzf] )); then
  [[ -t 0 && -o zle ]] && source <(fzf --zsh)   # needs a tty line editor: skipped in non-tty shells (agent snapshots)
  if (( $+commands[fd] )); then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
    export FZF_CTRL_T_COMMAND=$FZF_DEFAULT_COMMAND
    export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
  fi
  if (( $+commands[bat] )); then
    export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {} 2>/dev/null | head -200'"
  fi
fi

export EDITOR="nvim"
export GIT_EDITOR="nvim"
export VISUAL="nvim"
export TERMINAL="ghostty"
export BROWSER="flatpak run app.zen_browser.zen"

export MOZ_ENABLE_WAYLAND=1
export MOZ_GTK_TITLEBAR_DECORATION=client
export XCURSOR_SIZE=32

export NVM_DIR="$HOME/.nvm"

[ -f "$HOME/dotfiles/env.secret.sh" ] && source "$HOME/dotfiles/env.secret.sh"

[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  

[ -s "/home/$USER/.bun/_bun" ] && source "/home/$USER/.bun/_bun"

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

alias tdterm='ghostty -e su - td -c "tmux set-environment -g XDG_RUNTIME_DIR /run/user/1000; tmux set-environment -g WAYLAND_DISPLAY wayland-1; tmux source-file ~/.config/tmux/tmux.conf; exec tmux new-session -A -s main" &'

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

alias lzd="lazydocker"

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

# was rg(): shadowed ripgrep (false "no matches" for agents via the shell snapshot)
grun() {
  if [ -f "./main.go" ]; then 
    go run . "$@"
  elif [ -f "./cmd/main.go" ]; then
    go run ./cmd/main.go "$@"
  elif [ -f "./cmd/api/main.go" ]; then
    go run ./cmd/api/main.go "$@"
  fi
}
alias lg="golangci-lint run --fix; go mod tidy"
alias lgw="golangci-lint run > lint.dev 2>&1"
alias lgr='find . -name "go.mod" -execdir sh -c "golangci-lint run --fix; go mod tidy" \;'
alias tg="go test ./..."

alias lf="facad"

eval "$(zoxide init zsh)"

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

# Added by Antigravity CLI installer
export PATH="$HOME/.npm-global/bin:$PATH"

# Launch Codex without approval prompts or sandboxing.
codex() {
  command "$HOME/.local/bin/codex" --dangerously-bypass-approvals-and-sandbox "$@"
}

# ── AI agent cockpit ────────────────────────────────────────────────────────
# tmux: attach to the "main" session or create it
ta() { tmux new-session -A -s "${1:-main}"; }
alias wm="workmux"
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"

# ── Human-only conveniences ─────────────────────────────────────────────────
# Aliases that change command output stay out of agent shells: Claude Code captures this
# file into its shell snapshot, and agents must see stock ls/cat/etc.
if [[ -z $CLAUDECODE ]]; then
  if (( $+commands[eza] )); then
    alias ls='eza --group-directories-first'
    alias ll='eza -la --git --group-directories-first'
    alias lt='eza -T -L2 --git-ignore'
  fi
  (( $+commands[trash-put] )) && alias tp='trash-put'
  (( $+commands[bat] )) && export BAT_THEME=ansi   # inherits the terminal palette
fi

(( $+commands[direnv] )) && eval "$(direnv hook zsh)"

# ── Maintenance helpers ─────────────────────────────────────────────────────
# One command for system upgrades: news first, then packages, flatpaks, pacnew, cache, status.
sysup() {
  yay -Pw                                               # Arch news: read before upgrading
  read -q "?Upgrade now? [y/N] " || { echo; return 1 }; echo
  yay -Syu --sudoloop || return
  (( $+commands[flatpak] )) && flatpak update -y
  (( $+commands[pacdiff] )) && sudo pacdiff -o | sed 's/^/pacnew: /'   # merge: sudo DIFFPROG='nvim -d' pacdiff
  if (( $+commands[paccache] )); then
    sudo paccache -rk2; sudo paccache -ruk0
  fi
  [[ "$(pacman -Q linux | awk '{print $2}' | sed 's/\.arch/-arch/')" != "$(uname -r)" ]] && echo ">> kernel updated: reboot"
  systemctl --failed --no-legend; systemctl --user --failed --no-legend
}

# fzf toggle for the VPN/proxy daemons that exist on this machine
vpn() {
  local u; local -a cands
  for u in v2raya v2ray xray pritunl-client happd snap.surfshark.surfsharkd; do
    systemctl cat "$u.service" &>/dev/null && cands+=("$u")
  done
  (( $#cands )) || { echo "vpn: no known VPN service units installed"; return 1 }
  u=$(printf '%s\n' $cands | fzf --prompt='toggle vpn> ' --preview 'systemctl status {} --no-pager | head -15') || return
  if systemctl is-active -q "$u"; then sudo systemctl stop "$u"; else sudo systemctl start "$u"; fi
  systemctl is-active "$u"
}

# utility hub: fuzzy list of actions, toggles and keybinds (SUPER+M / tmux prefix+m). hub --help for the flags
hub() { "$HOME/.config/hub/hub" "$@" }

# fuzzy journal: jf [journalctl args], e.g. jf -p err  /  jf -u docker  /  jf --user
jf() { journalctl -b -o short-iso --no-pager "$@" | fzf --tac --no-sort --exact; }
