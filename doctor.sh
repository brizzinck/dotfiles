#!/usr/bin/env bash
# dotfiles doctor: asserts that the approved workstation state stays in place. Read-only, no sudo.
#   ./doctor.sh              print PASS/FAIL lines and a summary (exit 1 when anything failed)
#   ./doctor.sh --fails      print only the failures
# Repo-only (listed in .stow-local-ignore). Declined items (ufw, restic, keyring, ...) are intentionally not checked.
set -u

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY_FAILS=0
[ "${1:-}" = "--fails" ] && ONLY_FAILS=1

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); [ "$ONLY_FAILS" = 1 ] || printf 'PASS  %-18s %s\n' "$1" "${2:-}"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %-18s %s\n' "$1" "${2:-}"; }
check() { # check <name> <ok-detail> <fail-detail> <command...>
  local name="$1" okd="$2" badd="$3"
  shift 3
  if "$@" >/dev/null 2>&1; then ok "$name" "$okd"; else bad "$name" "$badd"; fi
}

# Hyprland instance (hyprctl needs the signature; fall back to the newest instance dir of this user)
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  sig="$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)"
  [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

# ── lockscreen ──────────────────────────────────────────────────────────────────
lock_cmd="$(sed -n 's/^[[:space:]]*lock_cmd[[:space:]]*=[[:space:]]*//p' "$HOME/.config/hypr/hypridle.conf" 2>/dev/null | head -1)"
if [ -z "$lock_cmd" ]; then
  bad lockscreen "no lock_cmd in ~/.config/hypr/hypridle.conf"
else
  missing=""
  # every command word of the lock_cmd alternatives (a || b && c ...) must resolve; shell builtins/pidof are fine
  for word in $(printf '%s' "$lock_cmd" | tr '|&;' '\n' | awk 'NF{print $1}'); do
    command -v "$word" >/dev/null 2>&1 || missing="$missing $word"
  done
  if [ -z "$missing" ]; then ok lockscreen "lock_cmd '$lock_cmd' resolves"; else bad lockscreen "lock_cmd '$lock_cmd': not found:$missing"; fi
fi

# ── idle: clock screensaver without a password, never an automatic suspend ──────
idle_conf="$HOME/.config/hypr/hypridle.conf"
if grep -Eq '^[[:space:]]*on-timeout[[:space:]]*=.*(suspend|lock-session)' "$idle_conf" 2>/dev/null; then
  bad idle-screensaver "hypridle.conf has an idle listener that suspends or locks with a password"
elif ! grep -q 'screensaver.sh start' "$idle_conf" 2>/dev/null; then
  bad idle-screensaver "hypridle.conf has no screensaver listener"
elif [ ! -x "$HOME/.config/hypr/scripts/screensaver.sh" ] || [ ! -r "$HOME/.config/hypr/screensaver.conf" ] || [ ! -x "$HOME/.config/hypr/idle-allowed.sh" ]; then
  bad idle-screensaver "screensaver.sh / screensaver.conf / idle-allowed.sh missing or not executable"
else
  ok idle-screensaver "idle starts the no-password clock screensaver; no auto-suspend"
fi

# ── session GPU env must not point at a non-AMD driver (this laptop is AMD-only) ─
hl_pid="$(pgrep -xo Hyprland 2>/dev/null || true)"
if [ -z "$hl_pid" ]; then
  bad hypr-env "Hyprland is not running, cannot inspect"
else
  # a direct child of Hyprland got the environment after `env =` lines were applied; Hyprland's own /proc environ did not
  child="$(pgrep -P "$hl_pid" 2>/dev/null | head -1)"
  leak="$(tr '\0' '\n' <"/proc/${child:-$hl_pid}/environ" 2>/dev/null |
    grep -E '^(LIBVA_DRIVER_NAME|GBM_BACKEND)=' | grep -vE '=(radeonsi|mesa)?$' | tr '\n' ' ')"
  if [ -z "$leak" ]; then ok hypr-env "no non-AMD LIBVA/GBM driver in the session"; else bad hypr-env "set: ${leak}(re-login to pick up the current hyprland.conf)"; fi
fi

# ── packages / timers / services ────────────────────────────────────────────────
if grep -qi 'GenuineIntel' /proc/cpuinfo; then ucode=intel-ucode; else ucode=amd-ucode; fi
check ucode "$ucode installed" "$ucode missing (sudo ~/dotfiles/apply-system.sh --only install)" pacman -Q "$ucode"
for t in fstrim paccache reflector; do
  check "$t.timer" "enabled" "not enabled (sudo ~/dotfiles/apply-system.sh --only services)" systemctl is-enabled "$t.timer"
done
# informational (never counted as a failure)
info() { printf 'INFO  %-18s %s\n' "$1" "${2:-}"; }
if systemctl --user is-enabled sysalert.timer >/dev/null 2>&1; then info sysalert "timer enabled"; else info sysalert "timer not enabled (systemctl --user enable --now sysalert.timer)"; fi
for c in ddcutil tlpctl rofi-calc ccusage pik; do
  if command -v "$c" >/dev/null 2>&1 || { [ "$c" = rofi-calc ] && [ -e /usr/lib/rofi/calc.so ]; }; then info "u4-$c" "installed"; else info "u4-$c" "missing (sudo ~/dotfiles/apply-system.sh --only install)"; fi
done
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then info i2c-group "member"; else info i2c-group "not in group i2c (log in again after the root script)"; fi
# Bitwarden / Vaultwarden (rbw): informational only
if ! command -v rbw >/dev/null 2>&1; then
  info rbw "not installed (sudo ~/dotfiles/apply-system.sh --only install)"
elif [ -s "${XDG_CONFIG_HOME:-$HOME/.config}/rbw/config.json" ] && jq -e '.email != null' "${XDG_CONFIG_HOME:-$HOME/.config}/rbw/config.json" >/dev/null 2>&1; then
  if rbw unlocked >/dev/null 2>&1; then info rbw "configured, unlocked"; else info rbw "configured, locked (master password on first use)"; fi
else
  info rbw "installed but not configured (run bw-setup)"
fi
# official Bitwarden CLI and the opt-in desktop SSH agent: informational only
if ! command -v bw >/dev/null 2>&1; then
  info bw "not installed (sudo ~/dotfiles/apply-system.sh --only install)"
else
  bw_st="$(BW_NOINTERACTION=true NODE_NO_WARNINGS=1 bw status 2>/dev/null | jq -r '.status // empty' 2>/dev/null)"
  case "$bw_st" in
    unauthenticated) info bw "installed, not logged in (run bw-setup)" ;;
    locked | unlocked)
      if [ -s "${XDG_RUNTIME_DIR:-/tmp}/vault/bw-session" ]; then info bw "logged in, CLI session open"; else info bw "logged in, CLI locked (master password on first use)"; fi ;;
    *) info bw "installed, status unknown (run bw-setup)" ;;
  esac
fi
if [ -f "${XDG_STATE_HOME:-$HOME/.local/state}/vault/ssh-agent" ]; then
  if [ -S "${BITWARDEN_SSH_AUTH_SOCK:-$HOME/.bitwarden-ssh-agent.sock}" ]; then info ssh-agent "Bitwarden SSH agent flag on, socket present"; else info ssh-agent "Bitwarden SSH agent flag on, socket absent (desktop app not running or agent not enabled in its settings)"; fi
else
  info ssh-agent "Bitwarden SSH agent flag off (vault.sh ssh-agent on)"
fi
check earlyoom "active" "not active (sudo ~/dotfiles/apply-system.sh --only services)" systemctl is-active earlyoom.service

# ── interactive zsh must not shadow rg / id ─────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
  # the interactive shell may print a banner, so the result is a tagged line
  shadow="$(zsh -i -c 'for c in rg id; do t=$(whence -w $c 2>/dev/null); case "$t" in *": command") ;; *) r="$r$c($t) " ;; esac; done; print -r -- "DOCTOR:$r"' 2>/dev/null </dev/null |
    sed -n 's/^.*DOCTOR://p' | tail -1)"
  if [ -z "$shadow" ]; then ok zsh-shadowing "rg and id resolve to the real commands"; else bad zsh-shadowing "shadowed: $shadow"; fi
else
  bad zsh-shadowing "zsh not installed"
fi

# ── docker ──────────────────────────────────────────────────────────────────────
if [ "$(jq -r '.builder.gc.enabled // false' /etc/docker/daemon.json 2>/dev/null)" = "true" ]; then
  ok docker-gc "builder.gc enabled in /etc/docker/daemon.json"
else
  bad docker-gc "builder.gc missing in /etc/docker/daemon.json (sudo ~/dotfiles/apply-system.sh --only config)"
fi

# ── pacman cache / pacnew ───────────────────────────────────────────────────────
cache_mb="$(du -sm /var/cache/pacman/pkg 2>/dev/null | cut -f1)"
if [ -z "$cache_mb" ]; then
  bad pacman-cache "cannot read /var/cache/pacman/pkg"
elif [ "$cache_mb" -le 8192 ]; then
  ok pacman-cache "${cache_mb} MiB (limit 8192)"
else
  bad pacman-cache "${cache_mb} MiB > 8192 (run: paccache -rk2 -ruk0)"
fi
pacnew="$(find /etc -xdev \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null | wc -l)"
if [ "$pacnew" = 0 ]; then ok pacnew "none"; else bad pacnew "$pacnew file(s) (run: pacdiff)"; fi

# ── failed units ────────────────────────────────────────────────────────────────
sys_failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
if [ -z "$sys_failed" ]; then ok failed-system "none"; else bad failed-system "$sys_failed"; fi
usr_failed="$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
if [ -z "$usr_failed" ]; then ok failed-user "none"; else bad failed-user "$usr_failed"; fi

# ── swap / zram ─────────────────────────────────────────────────────────────────
if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; then
  used="$(free -m | awk '/^Swap:/{ if ($2>0) printf "%d", $3*100/$2; else print 0 }')"
  if [ "$used" -lt 75 ]; then ok swap-zram "zram active, swap ${used}% used"; else bad swap-zram "zram active but swap ${used}% used (>=75%)"; fi
else
  bad swap-zram "no zram swap device active"
fi

# ── Hyprland / waybar ───────────────────────────────────────────────────────────
if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  errs="$(hyprctl configerrors 2>&1 | sed '/^[[:space:]]*$/d')"
  if [ -z "$errs" ]; then ok hypr-config "hyprctl configerrors is empty"; else bad hypr-config "$(printf '%s' "$errs" | head -1)"; fi
else
  bad hypr-config "no running Hyprland instance to query"
fi
n_bar="$(pgrep -xc waybar 2>/dev/null || true)"
if [ "${n_bar:-0}" = 1 ]; then ok waybar "single instance"; else bad waybar "${n_bar:-0} instances (expected 1)"; fi

# ── stow symlinks: every tracked config file must resolve to the repo copy ──────
broken=""
n_links=0
while IFS= read -r -d '' rel; do
  case "$rel" in
    .config/* | .zshrc | .gitconfig | .tmux.conf | .profile | .zprofile | .bashrc) ;;
    *) continue ;;
  esac
  n_links=$((n_links + 1))
  [ "$(readlink -f "$HOME/$rel" 2>/dev/null)" = "$(readlink -f "$DOTFILES/$rel")" ] || broken="$broken $rel"
done < <(git -C "$DOTFILES" ls-files -z)
if [ -z "$broken" ]; then
  ok stow-links "$n_links tracked paths resolve into the repo"
else
  # shellcheck disable=SC2086
  bad stow-links "$(echo $broken | wc -w) broken, first: $(echo $broken | cut -d' ' -f1-3) (run: cd ~/dotfiles && stow --restow .)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
