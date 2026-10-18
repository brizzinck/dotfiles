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

# Everforest variant (black | night): ghostty, tmux, fzf, delta and nvim read ~/.local/state/theme/current, which the
# `theme` command flips. Recreate the default (black) when the link is missing, e.g. on a fresh machine.
[[ -e ${XDG_STATE_HOME:-$HOME/.local/state}/theme/current || ! -x $HOME/.local/bin/theme ]] || "$HOME/.local/bin/theme" init 2>/dev/null

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
  vi-mode
  fzf-tab
  zsh-autosuggestions
  zsh-syntax-highlighting
)

ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'   # ANSI 8 = muted in the Everforest palette (both variants)

# vi-mode plugin (oh-my-zsh): beam cursor in INSERT, block in NORMAL; the [I]/[N] indicator lives in
# ~/.config/zsh/vi-mode.zsh (sourced below). KEYTIMEOUT is in 1/100 s: 1 = Esc -> NORMAL at once, tmux escape-time is 10 ms too
# (a slow ssh link needs more, so remote shells get 20 ms).
VI_MODE_SET_CURSOR=true
VI_MODE_RESET_PROMPT_ON_MODE_CHANGE=true
VI_MODE_CURSOR_NORMAL=2   # steady block
VI_MODE_CURSOR_INSERT=6   # steady beam
VI_MODE_CURSOR_VISUAL=4   # steady underline
KEYTIMEOUT=1
[[ -n $SSH_CONNECTION ]] && KEYTIMEOUT=2

# never block on a key press: the default mode asks "update now?" on the terminal about every 13 days, which stalls the
# login shell that greetd starts on a bare tty (hypr-login) until a key is pressed
zstyle ':omz:update' mode reminder

source $ZSH/oh-my-zsh.sh

# ── Prompt and highlighting on the palette roles ────────────────────────────────────────────────────
# ANSI indices follow the terminal palette, so both variants share this: ok arrow green, failing arrow red, dir blue
# (like ls/eza), git branch purple (red means "error" here), dirty marker yellow, punctuation muted.
# git info is computed once per prompt (precmd), not on every redraw: a vi-mode switch redraws the prompt each time
autoload -Uz add-zsh-hook
_df_git_info() { _DF_GIT_INFO=$(git_prompt_info) }
add-zsh-hook precmd _df_git_info
PROMPT='%(?:%F{2}%B%1{➜%}%b:%F{1}%B%1{➜%}%b) %F{4}%c%f ${_ENVS_PROMPT}${_DF_GIT_INFO}'
ZSH_THEME_GIT_PROMPT_PREFIX='%F{8}git:(%F{5}'
ZSH_THEME_GIT_PROMPT_SUFFIX='%f '
ZSH_THEME_GIT_PROMPT_DIRTY='%F{8}) %F{3}%1{✗%}'
ZSH_THEME_GIT_PROMPT_CLEAN='%F{8})'
[[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/envs.zsh ]] && source ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/envs.zsh   # [stage] / [prod] marker (envs use)
# zsh-syntax-highlighting paints comments black+bold = ANSI 0, which is the near-invisible `select` surface
ZSH_HIGHLIGHT_STYLES[comment]='fg=8'
# dircolors defaults put blue on green (ow), black on green (tw) and white on blue (st): invisible or loud
[[ $LS_COLORS == *:st=01\;34 ]] || export LS_COLORS="$LS_COLORS:ow=01;34:tw=01;34:st=01;34"
export EZA_COLORS="${EZA_COLORS:-xx=90}"   # eza punctuation: xterm grey 244 -> ANSI 8 (muted)

# ── History ─────────────────────────────────────────────────────────────────
HISTSIZE=200000
SAVEHIST=200000
setopt HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS

# ── fzf: Ctrl-R history, Ctrl-T files, Alt-C dirs (fd/bat only when installed) ──
if (( $+commands[fzf] )); then
  # Everforest colours of the active variant (hub, tmux popups and the pkg/vault scripts load the same file)
  [[ -r ${XDG_STATE_HOME:-$HOME/.local/state}/theme/current/fzfrc ]] && export FZF_DEFAULT_OPTS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/theme/current/fzfrc"
  [[ -t 0 && -o zle ]] && source <(fzf --zsh)   # needs a tty line editor: skipped in non-tty shells (agent snapshots)
  if (( $+commands[fd] )); then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
    export FZF_CTRL_T_COMMAND=$FZF_DEFAULT_COMMAND
    export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
  fi
  if (( $+commands[bat] )); then
    FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {} 2>/dev/null | head -200'"   # not exported: vi-mode.zsh appends the modal keys per call
  fi
fi

# Layout-independent keys: Cyrillic (ua/ru) twins of the Alt+letter widgets (fzf Alt-C, ...). ghostty already sends
# ESC + the us letter for Alt+<physical key> (ghostty/layout-keys.conf); this covers terminals that send ESC + UTF-8.
# layout_dup_keys (same file) is for the vi keymaps in stage V1. Table and map: ~/.config/layout/.
if [[ -o zle && -r ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/layout-keys.zsh ]]; then
  source ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/layout-keys.zsh
  layout_dup_meta emacs
fi
# vi-mode keys, indicator, Cyrillic twins of the vi keymaps and the modal fzf widgets (needs the fzf widgets above)
[[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/vi-mode.zsh ]] && source ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/vi-mode.zsh

# lazygit colours of the active variant: generated gui.theme merged after the structural config (only when the
# generated file exists, lazygit refuses a list with a missing file); tmux and hub set the same value
[[ -r ${XDG_STATE_HOME:-$HOME/.local/state}/theme/current/lazygit.yml ]] && export LG_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/lazygit/config.yml,${XDG_STATE_HOME:-$HOME/.local/state}/theme/current/lazygit.yml"

export EDITOR="nvim"
export GIT_EDITOR="nvim"
export VISUAL="nvim"
export TERMINAL="ghostty"
export BROWSER="flatpak run app.zen_browser.zen"

export MOZ_ENABLE_WAYLAND=1
export MOZ_GTK_TITLEBAR_DECORATION=client
export XCURSOR_SIZE=32
export HYPRCURSOR_SIZE=32
# Pointer theme in the environment of the login shell that starts Hyprland (greetd -> hypr-login -> zsh -l -i -> start-hyprland),
# so the compositor has it at its own start; same choice as hyprland.lua: Everforest-Cursor once installed, else Bibata.
if [[ -r /usr/share/icons/Everforest-Cursor/manifest.hl && -r /usr/share/icons/Everforest-Cursor/cursors/left_ptr ]]; then
  export XCURSOR_THEME=Everforest-Cursor HYPRCURSOR_THEME=Everforest-Cursor
else
  export XCURSOR_THEME=Bibata-Modern-Ice
fi

# secrets: ~/.config/secrets/env.sh (0600; the place for managed users) and, for the owner, ~/dotfiles/env.secret.sh
for _f in "$HOME/.config/secrets/env.sh" "$HOME/dotfiles/env.secret.sh"; do [ -f "$_f" ] && source "$_f"; done; unset _f
# per-user overrides that are never shared (usr link writes the accent marker of a managed user's prompt here)
[ -r "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
# per-command hooks (atuin recording, long-command notification), Ctrl+R over atuin, completion extras: not for agents.
# After ~/.zshrc.local, so DF_CMD_NOTIFY_MIN & co can be set there; every file is optional and returns early without zle.
if [[ -z $CLAUDECODE ]]; then
  for _f in cmd-hooks history completion; do
    [[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/$_f.zsh ]] && source ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/$_f.zsh
  done; unset _f
fi

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

alias tdterm='usr term td'   # managed users: usr list | usr term USER | SUPER+SHIFT+T

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

# The absolute path of envs, fixed when the shell starts and READONLY: a project's mise `_.path` or a pinned tool dir can hold an
# `envs` of its own that would see the secrets, and its [env] can set HOME (or even _ENVS_BIN) after this line ran. The home is
# the account's from the password database (`~user`), not $HOME, and an _ENVS_BIN imported from the environment is dropped.
# `envs`, `er`, `ere`, `ert` all use it.
zmodload zsh/parameter
if [[ ${parameters[_ENVS_BIN]-} != *readonly* ]]; then
  unset _ENVS_BIN
  [[ $USERNAME =~ '^[A-Za-z0-9_.-]+$' ]] && eval "typeset -gr _ENVS_BIN=~${USERNAME}/.local/bin/envs"
  [[ -n ${_ENVS_BIN-} ]] || typeset -g _ENVS_BIN=$HOME/.local/bin/envs
fi
envs() { $_ENVS_BIN "$@" }

# Run a command with the project's secrets of the active environment (envs: they live in Bitwarden and reach only the command,
# never this shell; a function or alias such as grun cannot be wrapped, use the real command: er go run .)
er() { $_ENVS_BIN run -- "$@" }
# Run a command with the project's secrets of environment ENV (ere stage go test ./...)
ere() { local e=$1; shift; $_ENVS_BIN run -e "$e" -- "$@" }
# Run a mise task with the project's secrets (ert test)
ert() { $_ENVS_BIN run -- mise run "$@" }

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
# Opt-in Bitwarden desktop SSH agent (`vault.sh ssh-agent on`): used only while its socket exists, so git over SSH keeps
# working with the agent above when the app is not running. ~/.ssh and its keys are never touched.
if [[ -f ${XDG_STATE_HOME:-$HOME/.local/state}/vault/ssh-agent && -S ${BITWARDEN_SSH_AUTH_SOCK:-$HOME/.bitwarden-ssh-agent.sock} ]]; then
  export SSH_AUTH_SOCK="${BITWARDEN_SSH_AUTH_SOCK:-$HOME/.bitwarden-ssh-agent.sock}"
fi

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
  # man pages through less colours: bold = green, underline = blue (ANSI, so both variants); MANROFFOPT keeps SGR
  export MANPAGER='less -R --use-color -Dd+g -Du+b'
  export MANROFFOPT='-P -c'
fi

# mise: tool versions per project (non-secret [env] too); replaces direnv. Secrets never live in the shell: `envs run`, see CLAUDE.md
[[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/mise.zsh ]] && source ${XDG_CONFIG_HOME:-$HOME/.config}/zsh/mise.zsh

# ── Maintenance helpers ─────────────────────────────────────────────────────
# System upgrades: `sysup` is ~/.local/bin/sysup (background check + download, install only when you run it:
# keyring, pacman + AUR, flatpak, dev tools, nvim, zsh/tmux plugins, report). `sysup --help`, `sysup check`, `sysup log`.

# fzf-menu (shared modal fzf, vim keys) toggle for the VPN/proxy daemons that exist on this machine
vpn() {
  local u; local -a cands
  for u in v2raya v2ray xray pritunl-client happd snap.surfshark.surfsharkd; do
    systemctl cat "$u.service" &>/dev/null && cands+=("$u")
  done
  (( $#cands )) || { echo "vpn: no known VPN service units installed"; return 1 }
  u=$(printf '%s\n' $cands | fzf-menu --here -p 'toggle vpn' --preview 'systemctl status {} --no-pager | head -15') || return
  if systemctl is-active -q "$u"; then sudo systemctl stop "$u"; else sudo systemctl start "$u"; fi
  systemctl is-active "$u"
}

# utility hub: fuzzy list of actions, toggles and keybinds (SUPER+M / tmux prefix+m). hub --help for the flags
hub() { "$HOME/.config/hub/hub" "$@" }

# fuzzy journal: jf [journalctl args], e.g. jf -p err  /  jf -u docker  /  jf --user
jf() { journalctl -b -o short-iso --no-pager "$@" | fzf-menu --here -p journal --tac --no-sort --exact; }

# >>> skw completion >>>
# Managed by skw; remove with "skw completion uninstall".
(( ${fpath[(Ie)"$HOME/.local/share/zsh/site-functions"]} )) || fpath=("$HOME/.local/share/zsh/site-functions" $fpath)
if (( $+functions[compdef] )); then
  autoload -Uz _skw && compdef _skw skw
else
  autoload -Uz compinit && compinit -i
fi
# <<< skw completion <<<
