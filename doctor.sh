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
  if [ -z "$leak" ]; then ok hypr-env "no non-AMD LIBVA/GBM driver in the session"; else bad hypr-env "set: ${leak}(re-login to pick up the current hyprland.lua)"; fi
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
for c in ddcutil tlpctl ccusage pik; do
  if command -v "$c" >/dev/null 2>&1; then info "u4-$c" "installed"; else info "u4-$c" "missing (sudo ~/dotfiles/apply-system.sh --only install)"; fi
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

# ── wallpaper: palette-driven vector, one swaybg per output, no raster in the repo (W2) ──────────────────────────
wp_err=""
for v in black night; do
  svgf="$DOTFILES/themes/generated/$v/wallpaper.svg"
  fillv="$(jq -r '.tokens.green_soft' "$DOTFILES/themes/generated/$v/tokens.json" 2>/dev/null)"
  if [ ! -s "$svgf" ]; then wp_err="$wp_err $v: wallpaper.svg missing;"
  elif ! grep -q "fill=\"$fillv\"" "$svgf"; then wp_err="$wp_err $v: fill is not green_soft ($fillv);"; fi
done
raster="$(git -C "$DOTFILES" ls-files themes | grep -Ei '\.(png|jpe?g|webp|bmp|gif)$' | head -3 | tr '\n' ' ')"
[ -z "$raster" ] || wp_err="$wp_err raster committed under themes/: $raster;"
if [ -n "$hl_pid" ]; then
  while read -r mon; do
    n="$(pgrep -af '^swaybg ' | grep -c -- "-o $mon ")"
    [ "$n" = 1 ] || wp_err="$wp_err $mon has $n swaybg (want 1);"
  done < <(hyprctl monitors -j 2>/dev/null | jq -r '.[].name')
  [ "$(pgrep -cx swaybg)" = "$(hyprctl monitors -j 2>/dev/null | jq length)" ] || wp_err="$wp_err swaybg count differs from the connected outputs;"
fi
if [ -z "$wp_err" ]; then ok wallpaper "wallpaper.svg = green_soft in both variants, one swaybg per output, no raster in themes/"; else bad wallpaper "${wp_err# }"; fi

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
# The config is Lua: hyprland.lua is the only entry point, a leftover hyprland.conf must not exist (the .conf format is
# deprecated and goes away in Hyprland 0.57), and the live bind table must come from the Lua file (Lua binds report the
# dispatcher "__lua").
conf_dir="$HOME/.config/hypr"
if [ -f "$conf_dir/hyprland.lua" ] && [ ! -e "$conf_dir/hyprland.conf" ] && [ ! -e "$DOTFILES/.config/hypr/hyprland.conf" ]; then
  ok hypr-lua-files "hyprland.lua present, hyprland.conf absent"
else
  bad hypr-lua-files "need $conf_dir/hyprland.lua and no hyprland.conf (also not in the repo)"
fi
if command -v Hyprland >/dev/null 2>&1 && [ -f "$conf_dir/hyprland.lua" ]; then
  if Hyprland --verify-config -c "$conf_dir/hyprland.lua" 2>&1 | grep -q '^config ok'; then
    ok hypr-verify "Hyprland --verify-config accepts hyprland.lua"
  else
    bad hypr-verify "Hyprland --verify-config rejects hyprland.lua (run it by hand for the message)"
  fi
fi
if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  errs="$(hyprctl configerrors 2>&1 | sed '/^[[:space:]]*$/d')"
  if [ -z "$errs" ]; then ok hypr-config "hyprctl configerrors is empty"; else bad hypr-config "$(printf '%s' "$errs" | head -1)"; fi
  binds_json="$(hyprctl binds -j 2>/dev/null)"
  n_lua="$(printf '%s' "$binds_json" | jq '[.[] | select(.dispatcher == "__lua")] | length' 2>/dev/null || echo 0)"
  n_all="$(printf '%s' "$binds_json" | jq 'length' 2>/dev/null || echo 0)"
  if [ "${n_all:-0}" -gt 0 ] && [ "$n_lua" = "$n_all" ]; then
    ok hypr-loaded "the running Hyprland loaded hyprland.lua ($n_all binds, all from Lua)"
  else
    bad hypr-loaded "live bind table has $n_lua Lua binds of $n_all: the running instance is not on hyprland.lua (log in again)"
  fi
  # every hub row of kind bind (and the leader menu) replays a bind by its key text: that bind must exist
  stale="$("$DOTFILES/.config/hub/hub" --raw 2>/dev/null | awk -F"$(printf '\037')" '$5 == "bind" && $1 !~ /^bind:/ { print $6 }' |
    while IFS= read -r label; do
      printf '%s' "$binds_json" | jq -e --arg l "$label" '
        def mods($m): [ (if ($m / 64 | floor) % 2 == 1 then "SUPER" else empty end), (if ($m / 4 | floor) % 2 == 1 then "CTRL" else empty end),
                        (if ($m / 8 | floor) % 2 == 1 then "ALT" else empty end), (if $m % 2 == 1 then "SHIFT" else empty end) ];
        any(.[]; .submap == "" and ((mods(.modmask) + [.key]) | join("+") | ascii_downcase) == ($l | ascii_downcase))' >/dev/null || printf '%s ' "$label"
    done)"
  if [ -z "$stale" ]; then ok hub-binds "every hub bind row names a live keybind"; else bad hub-binds "no such keybind: $stale"; fi
else
  bad hypr-config "no running Hyprland instance to query"
fi
if [ -x "$DOTFILES/.config/hub/leader" ]; then
  if out="$(PYTHONPYCACHEPREFIX=/tmp/pycache "$DOTFILES/.config/hub/leader" check 2>&1)"; then ok leader-menu "$out"; else bad leader-menu "$(printf '%s' "$out" | head -1)"; fi
else
  bad leader-menu ".config/hub/leader missing or not executable"
fi
# K2: the shortcut reference (keymap): docs/keymap.md equals a fresh generation, every pinned key exists, no block is empty,
# every described Hyprland bind appears once; the reading page loads nothing from the network
if [ -x "$DOTFILES/.local/bin/keymap" ]; then
  if out="$(PYTHONPYCACHEPREFIX=/tmp/pycache "$DOTFILES/.local/bin/keymap" check 2>&1)"; then ok keymap-doc "$out"; else bad keymap-doc "$(printf '%s' "$out" | head -1)"; fi
  if page="$(PYTHONPYCACHEPREFIX=/tmp/pycache "$DOTFILES/.local/bin/keymap" page --print 2>/dev/null)" && [ -s "$page" ]; then
    if grep -Eq '(src|href)="https?://|@import|url\(https?:|<link[^>]*stylesheet' "$page"; then bad keymap-page "$page loads something from the network"; else ok keymap-page "reading page renders offline ($(wc -c <"$page") bytes)"; fi
  else
    bad keymap-page "keymap page --print produced no page"
  fi
else
  bad keymap-doc ".local/bin/keymap missing or not executable"
fi
# U8: SUPER+CTRL+U types the Linux password of the user the focused window asks for (vault.sh user-pass + vault-who.py)
if [ -x "$DOTFILES/.config/hypr/scripts/vault.sh" ] && [ -r "$DOTFILES/.config/hypr/scripts/vault-who.py" ]; then
  if python3 -I "$DOTFILES/.config/hypr/scripts/vault-who.py" --pid "$$" --class doctor | jq -e '.kind == "other" and (.user | length > 0)' >/dev/null 2>&1; then
    ok vault-userpass "vault-who.py answers (offline probe on this shell)"
  else
    bad vault-userpass "vault-who.py does not answer (python3 -I .config/hypr/scripts/vault-who.py --pid \$\$ --class doctor)"
  fi
  if [ -n "${binds_json:-}" ]; then
    if printf '%s' "$binds_json" | jq -e 'any(.[]; .submap == "" and .modmask == 68 and (.key | ascii_downcase) == "u" and .has_description)' >/dev/null 2>&1; then
      ok vault-userpass-bind "SUPER+CTRL+U is bound (user-pass)"
    else
      bad vault-userpass-bind "SUPER+CTRL+U is not in the live bind table (hyprctl reload)"
    fi
  fi
  if "$DOTFILES/.config/hub/hub" --list --all 2>/dev/null | grep -q 'vault-user-pass'; then ok vault-userpass-row "hub row vault-user-pass exists"; else bad vault-userpass-row "hub row vault-user-pass missing (.config/hub/actions.d/u5.tsv)"; fi
  if command -v rbw >/dev/null 2>&1 && rbw unlocked >/dev/null 2>&1; then
    n_linux="$(rbw list --fields folder 2>/dev/null | grep -cx Linux || true)"
    if [ "${n_linux:-0}" -gt 0 ]; then info vault-linux "folder Linux: $n_linux login(s)"; else info vault-linux "no Bitwarden folder Linux yet (one login per Linux user, item name = user name)"; fi
  else
    info vault-linux "not checked (vault locked or rbw missing); the folder is Linux, one login per Linux user"
  fi
else
  bad vault-userpass "vault.sh or vault-who.py missing"
fi
# U9: the vault browser (vault-browse.py, SUPER+CTRL+SHIFT+P): bind, hub row, leader item and the offline test with fakes
if [ -r "$DOTFILES/.config/hypr/scripts/vault-browse.py" ]; then
  if [ -n "${binds_json:-}" ]; then
    if printf '%s' "$binds_json" | jq -e 'any(.[]; .submap == "" and .modmask == 69 and (.key | ascii_downcase) == "p" and .has_description)' >/dev/null 2>&1; then
      ok vault-browse-bind "SUPER+CTRL+SHIFT+P is bound (vault browser)"
    else
      bad vault-browse-bind "SUPER+CTRL+SHIFT+P is not in the live bind table (hyprctl reload)"
    fi
  fi
  if "$DOTFILES/.config/hub/hub" --list --all 2>/dev/null | grep -q 'vault-browse'; then ok vault-browse-row "hub row vault-browse exists"; else bad vault-browse-row "hub row vault-browse missing (.config/hub/actions.d/u9.tsv)"; fi
  if vb_out="$("$DOTFILES/infrastructure/tests/vault-browse/run.sh" --quick 2>&1)"; then
    ok vault-browse "offline test with fake rbw/bw: $(printf '%s' "$vb_out" | tail -1 | sed 's/^vault-browse quick test: //')"
  else
    bad vault-browse "offline test failed (infrastructure/tests/vault-browse/run.sh --quick): $(printf '%s' "$vb_out" | grep -m1 '^FAIL')"
  fi
else
  bad vault-browse ".config/hypr/scripts/vault-browse.py missing"
fi
# V1c: generated layout twins are current (tmux/rofi depend on running tools and are skipped by `layout.py check`), and the
# Obsidian vault carries the vimrc + vimMode (apps/obsidian/apply.sh); the Vimrc Support plugin itself is the owner's install
if lay_out="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 "$DOTFILES/.config/layout/layout.py" check 2>&1)"; then ok layout-gen "generated ua/ru twins are current (layout.py check)"; else bad layout-gen "stale: $(printf '%s' "$lay_out" | head -1) (layout.py gen)"; fi
if [ -x "$DOTFILES/apps/obsidian/apply.sh" ]; then
  obs_dry="$("$DOTFILES/apps/obsidian/apply.sh" --dry-run 2>&1)"
  if printf '%s' "$obs_dry" | grep -q 'no vault found'; then info obsidian-vim "no Obsidian vault registered yet"
  elif printf '%s' "$obs_dry" | grep -q 'would'; then bad obsidian-vim "vault vimrc/app.json out of date (apps/obsidian/apply.sh)"
  else ok obsidian-vim "vault has vimMode and the current .obsidian.vimrc"; fi
fi
# V1c: OBS control (obs-ctl over obs-cmd): hub rows, leader group o and the offline test with a fake obs-cmd
if [ -x "$HOME/.local/bin/obs-ctl" ]; then
  obs_rows="$("$DOTFILES/.config/hub/hub" --list --all 2>/dev/null | grep -c '^OBS ')"
  if [ "${obs_rows:-0}" -ge 7 ]; then ok obs-rows "hub rows for OBS ($obs_rows, .config/hub/actions.d/v1c.tsv)"; else bad obs-rows "hub rows for OBS missing (${obs_rows:-0}, .config/hub/actions.d/v1c.tsv)"; fi
  if obs_out="$("$DOTFILES/infrastructure/tests/obs-ctl/run.sh" 2>&1)"; then
    ok obs-ctl "offline test with a fake obs-cmd: $(printf '%s' "$obs_out" | tail -1 | sed 's/^obs-ctl test: //')"
  else
    bad obs-ctl "offline test failed (infrastructure/tests/obs-ctl/run.sh): $(printf '%s' "$obs_out" | grep -m1 '^FAIL')"
  fi
  if command -v obs-cmd >/dev/null 2>&1; then :; else info obs-cmd "obs-cmd is not installed: the OBS hub rows stay hidden"; fi
else
  bad obs-ctl ".local/bin/obs-ctl missing"
fi
# ── V1b: the shared modal fzf (vim keys in every menu) ──────────────────────────────────────────────────────────
if [ -x "$HOME/.local/bin/fzf-menu" ] && [ -r "$HOME/.config/fzf/vimfzf.sh" ]; then
  if out="$("$HOME/.local/bin/fzf-menu" --self-test 2>&1)"; then ok fzf-menu "modal self-test passed ($(printf '%s\n' "$out" | grep -c '^ok') cases)"; else bad fzf-menu "$(printf '%s\n' "$out" | grep -m1 'FAIL\|self-test')"; fi
  if [ -p "${XDG_RUNTIME_DIR:-/tmp}/fzf-menu/server.fifo" ] && kill -0 "$(cat "${XDG_RUNTIME_DIR:-/tmp}/fzf-menu/server.pid" 2>/dev/null)" 2>/dev/null; then info fzf-menu-server "hidden menu terminal running (menus open in ~40 ms)"; else info fzf-menu-server "not running: menus start a cold ghostty (~0.4 s); fzf-menu --server-start"; fi
else
  bad fzf-menu "fzf-menu or the fzf library (.local/bin, .config/fzf) is missing (run stow in ~/dotfiles)"
fi
left="$(grep -rlE 'rofi -dmenu|rofi-rbw|rofimoji ' "$DOTFILES/.config/hypr/scripts" "$DOTFILES/.config/hub" "$DOTFILES/.config/tmux/scripts" "$DOTFILES/.local/bin" 2>/dev/null | tr '\n' ' ')"
if [ -z "$left" ]; then ok rofi-dmenu "rofi is only the app launcher"; else bad rofi-dmenu "still calls rofi as a dmenu: $left"; fi
for c in wl-kbptr wlrctl wlr-which-key; do
  if command -v "$c" >/dev/null 2>&1; then info "v1-$c" "installed"; else info "v1-$c" "missing, its binds only notify (sudo ~/dotfiles/apply-system.sh --only install)"; fi
done
# count only top-level waybar processes: it forks a child (also named waybar) per script run
n_bar="$(ps -u "$(id -u)" -o pid=,ppid=,comm= 2>/dev/null | awk '$3 == "waybar" {p[$1] = 1; pp[$1] = $2} END {n = 0; for (i in p) if (!(pp[i] in p)) n++; print n}')"
if [ "${n_bar:-0}" = 1 ]; then ok waybar "single instance"; else bad waybar "${n_bar:-0} instances (expected 1)"; fi
# the watchdog (waybar-run.sh) restarts a crashed waybar; without it a crash leaves the screen without a bar until bar.sh restart
sup_pid="$(cat "${XDG_RUNTIME_DIR:-/tmp}/waybar-bar/supervisor.pid" 2>/dev/null)"
if [ -n "$sup_pid" ] && grep -qs waybar-run "/proc/$sup_pid/cmdline" 2>/dev/null; then ok bar-watchdog "waybar-run.sh supervises waybar (pid $sup_pid; restarts are in: journalctl -t waybar-run)"; else bad bar-watchdog "no waybar-run.sh supervisor running (a waybar crash would not be restarted; run: bar.sh restart)"; fi

# ── waybar (W1): config parses, state files match the mode, both bars sit where the design puts them ────────────
bar_sh="$HOME/.config/waybar/scripts/bar.sh"
bar_state="${XDG_STATE_HOME:-$HOME/.local/state}/waybar"
bar_err="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 -I - "$DOTFILES/.config/waybar" "$bar_state" <<'PY' 2>&1
import json, os, sys
cfgdir, state = sys.argv[1:3]

def jsonc(path):  # waybar accepts // comments; strip them outside of strings
    s, out, i, ins = open(path, encoding="utf-8").read(), [], 0, False
    while i < len(s):
        c = s[i]
        if ins:
            out.append(c)
            if c == "\\":
                out.append(s[i + 1]); i += 1
            elif c == '"':
                ins = False
        elif c == '"':
            ins = True; out.append(c)
        elif s.startswith("//", i):
            while i < len(s) and s[i] != "\n":
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return json.loads("".join(out))

problems = []
try:
    cfg = jsonc(f"{cfgdir}/config")
    mods = jsonc(f"{cfgdir}/modules.jsonc")
    jsonc(f"{cfgdir}/full-default.jsonc")
    try:  # the pinned apps are generated into the state dir (pinned.sh gen); the `pinned` check below verifies that file
        mods.update(jsonc(f"{state}/pinned.jsonc"))
    except OSError:
        pass
    names = [b.get("name") for b in cfg]
    if names != ["waybar-compact", "waybar-full"]:
        problems.append(f"config bars {names}")
    for b in cfg:
        for m in b["modules-left"] + b["modules-center"] + b["modules-right"]:
            if m not in mods:
                problems.append(f"{b['name']}: module {m} is not defined in modules.jsonc")
        for g in b["modules-right"]:
            if g.startswith("group/"):
                for m in mods[g]["modules"]:
                    if m not in mods:
                        problems.append(f"{g}: module {m} is not defined")
except Exception as e:  # noqa: BLE001
    problems.append(f"config: {e}")
try:
    mode = open(f"{state}/mode").read().strip()
    if mode not in ("compact", "full"):
        problems.append(f"mode file says '{mode}'")
    hidden = os.path.exists(f"{state}/hidden")
    want = {"compact": {"start_hidden": hidden}, "full": {"start_hidden": hidden or mode == "compact"}}
    for n, w in want.items():
        got = jsonc(f"{state}/{n}.jsonc")
        if got != w:
            problems.append(f"{n}.jsonc is {got}, expected {w}")
except Exception as e:  # noqa: BLE001
    problems.append(f"state: {e} (run: bar.sh init)")
print("; ".join(problems))
PY
)"
if [ -z "$bar_err" ]; then ok bar-state "config and modules.jsonc parse, mode $("$bar_sh" status 2>/dev/null), include files match the state"; else bad bar-state "$bar_err"; fi
if [ "${n_bar:-0}" -ge 1 ] && command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  bar_hidden=0; [ -e "$bar_state/hidden" ] && bar_hidden=1
  bar_mode="$("$bar_sh" status --short 2>/dev/null)"
  layers_err="$(jq -rn --argjson L "$(hyprctl layers -j 2>/dev/null)" --argjson M "$(hyprctl monitors -j 2>/dev/null)" \
    --argjson hidden "$bar_hidden" --arg mode "$bar_mode" '
    [ $M[] | . as $m
      | ($L[$m.name].levels // {} | to_entries
         | map(.key as $lv | .value[] | select(.namespace == "waybar-compact" or .namespace == "waybar-full") | {n: .namespace, lv: ($lv | tonumber), y: .y, h: .h})) as $s
      | ($s | map(select(.n == "waybar-compact")) | .[0]) as $c | ($s | map(select(.n == "waybar-full")) | .[0]) as $f
      | if ($c == null or $f == null) then "\($m.name): compact/full surface missing"
        elif $hidden == 1 then (if ($c.lv != 1 or $f.lv != 1) then "\($m.name): hidden but a bar is above the bottom layer" else empty end)
        elif ($c.y != $m.y or $f.y != $m.y) then "\($m.name): a bar is not at the top edge (y \($c.y)/\($f.y), expected \($m.y)); the negative margin was clamped, switch to the fallback in waybar-design.md 4.1"
        elif $mode == "full" and ($c.lv != 2 or $f.lv != 2) then "\($m.name): full mode but a bar is not on the top layer"
        elif $mode == "compact" and ($c.lv != 2 or $f.lv != 1) then "\($m.name): compact mode but the layers disagree (a stray SIGUSR1? run: bar.sh sync)"
        else empty end
    ] | join("; ")' 2>&1)"
  if [ -z "$layers_err" ]; then ok bar-layers "compact and full surfaces on every monitor match mode $bar_mode$([ "$bar_hidden" = 1 ] && echo ' (hidden)')"; else bad bar-layers "$layers_err"; fi
  want_top=28; [ "$bar_hidden" = 1 ] && want_top=0
  res_err="$(hyprctl monitors -j 2>/dev/null | jq -r --argjson w "$want_top" '[.[] | select(.reserved[1] != $w) | "\(.name) reserved \(.reserved[1])"] | join("; ")')"
  if [ -z "$res_err" ]; then ok bar-reserved "reserved top strip is ${want_top}px on every monitor"; else bad bar-reserved "$res_err (expected $want_top)"; fi
fi
# pinned apps (FIX-pinned): list parses, generated modules are current in both bars, the daemon runs, nothing else uses signal 14
pin_err="$("$HOME/.config/waybar/scripts/pinned.sh" check 2>&1)"
pin_sig="$(git -C "$DOTFILES" grep -nE 'RTMIN\+14' -- .config .local ':!.config/nvim' ':!.config/waybar/scripts/pinned*' ':!*.md' ':!.config/waybar/modules.jsonc' 2>/dev/null | head -2 | tr '\n' ' ')"
[ -n "$pin_sig" ] && pin_err="${pin_err:+$pin_err; }signal 14 is also used by: $pin_sig"
if [ -z "$pin_err" ]; then ok pinned "pinned.tsv ($(grep -cvE '^[[:space:]]*(#|$)' "$DOTFILES/.config/waybar/pinned.tsv") apps) -> group/pinned in both bars, pinned-watch.py running"; else bad pinned "$pin_err"; fi
css_hex="$(grep -nE '#[0-9a-fA-F]{3,8}\b' "$DOTFILES/.config/waybar/style.css" 2>/dev/null | head -2 | tr '\n' ' ')"
if [ -z "$css_hex" ]; then ok bar-css "style.css uses palette tokens only"; else bad bar-css "hex literal in style.css: $css_hex"; fi
# health badge: the module runs health-badge.sh (keeps the snapshot the details view lists) with signal 16, and a unit in a
# normal start job (activating, 0 restarts: a D-Bus activated daemon, a oneshot run by a timer) must not raise the alert
hb_dir="$(mktemp -d)"
printf '#!/bin/bash\n[[ $* == *--failed* ]] && exit 0\n[[ $* == *show\\ \\*.service* ]] && { printf "Id=upower.service\\nActiveState=activating\\nSubState=start\\nNRestarts=0\\n\\n"; exit 0; }\nexec /usr/bin/systemctl "$@"\n' >"$hb_dir/systemctl"
chmod +x "$hb_dir/systemctl"
hb_err=""
hb_mod="$(sed -n '/"custom\/health"/,/^  }/p' "$DOTFILES/.config/waybar/modules.jsonc")"
grep -q 'health-badge.sh' <<<"$hb_mod" && grep -q '"signal": 16' <<<"$hb_mod" || hb_err="custom/health must exec health-badge.sh with signal 16"
[ -x "$DOTFILES/.config/waybar/scripts/health-badge.sh" ] || hb_err="${hb_err:+$hb_err; }health-badge.sh is not executable"
hb_out="$(PATH="$hb_dir:$PATH" XDG_RUNTIME_DIR="$hb_dir" "$DOTFILES/.config/waybar/scripts/failed.sh" 2>/dev/null)"
[ "$(jq -r '.text // ""' <<<"$hb_out" 2>/dev/null)" = "" ] || hb_err="${hb_err:+$hb_err; }failed.sh raises an alert for a unit that is merely starting"
rm -rf "$hb_dir"
if [ -z "$hb_err" ]; then ok health-badge "custom/health -> health-badge.sh (signal 16); a unit in a plain start job does not alert"; else bad health-badge "$hb_err"; fi
raw_usr1="$(git -C "$DOTFILES" grep -nE 'USR1.*waybar|waybar.*USR1' -- .config .local ':!.config/nvim' ':!.config/waybar/scripts/bar.sh' ':!*.md' ':!.config/waybar/config' ':!.config/waybar/modules.jsonc' 2>/dev/null | head -2 | tr '\n' ' ')"
if [ -z "$raw_usr1" ]; then ok bar-sigusr1 "only bar.sh sends SIGUSR1 to waybar"; else bad bar-sigusr1 "raw SIGUSR1: $raw_usr1"; fi

# ── pointer (C1): Everforest-Cursor is a local package; until the root script installed it, Bibata is the fallback ──
cur_dir="${DOCTOR_CURSOR_DIR:-/usr/share/icons/Everforest-Cursor}"   # override for tests
if [ ! -r "$cur_dir/index.theme" ]; then
  info cursor "Everforest-Cursor not installed (sudo ~/dotfiles/apply-system.sh --only install); Bibata-Modern-Ice is the pointer, hyprland.lua falls back to it"
else
  cur_err=""
  [ -r "$cur_dir/manifest.hl" ] && [ -e "$cur_dir/cursors/left_ptr" ] && [ -r "$cur_dir/hyprcursors/left_ptr.hlc" ] || cur_err="theme dir incomplete (manifest.hl, cursors/left_ptr, hyprcursors/left_ptr.hlc)"
  if [ -z "$cur_err" ] && [ "$(cat "$cur_dir/.build-stamp" 2>/dev/null)" != "$("$DOTFILES/infrastructure/cursor/build.sh" --stamp 2>/dev/null)" ]; then
    cur_err="built from an older palette or PKGBUILD: run sudo ~/dotfiles/apply-system.sh --only install (rebuilds and installs it)"
  fi
  if [ -z "$cur_err" ]; then
    # roles: fill = green token, outline = accent = bg_oled token (accent = the busy cursor's pies, dark on the green disk)
    want="$(python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1]))["shared"]["tokens"]; print(t["green"].lower(), t["bg_oled"].lower())' "$DOTFILES/themes/palette/everforest.json" 2>/dev/null)"
    want_fill="${want% *}"; want_line="${want#* }"
    got="$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["fill"].lower(), p["outline"].lower(), p["accent"].lower())' "$DOTFILES/themes/generated/black/pointer.json" 2>/dev/null)"
    [ "$got" = "$want_fill $want_line $want_line" ] || cur_err="pointer.json is '$got', the palette wants fill=$want_fill (green) outline=accent=$want_line (bg_oled); rerun themes/palette/render.py"
  fi
  if [ -z "$cur_err" ]; then
    unzip -p "$cur_dir/hyprcursors/left_ptr.hlc" '*.svg' 2>/dev/null | grep -qi "fill=\"$want_fill\"" || cur_err="left_ptr fill is not $want_fill (sudo ~/dotfiles/apply-system.sh --only install)"
  fi
  if [ -z "$cur_err" ]; then
    unzip -p "$cur_dir/hyprcursors/left_ptr_watch.hlc" '*.svg' 2>/dev/null | grep -qi "fill=\"$want_fill\"" || cur_err="busy cursor disk is not $want_fill (sudo ~/dotfiles/apply-system.sh --only install)"
  fi
  if [ -z "$cur_err" ]; then ok cursor "Everforest-Cursor installed (hyprcursor + XCursor), fill green $want_fill, up to date with the palette"; else bad cursor "$cur_err"; fi
  if command -v gsettings >/dev/null 2>&1; then
    cur_gs="$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null | tr -d "'")"
    if [ "$cur_gs" = Everforest-Cursor ]; then ok cursor-gtk "gsettings cursor-theme is Everforest-Cursor"; else info cursor-gtk "gsettings cursor-theme is '$cur_gs' (log in again, or run cursor-apply)"; fi
  fi
fi
if grep -q 'cursor-apply --boot' "$DOTFILES/.config/hypr/hyprland.lua" && ! grep -q 'exec_cmd("hyprctl setcursor' "$DOTFILES/.config/hypr/hyprland.lua"; then ok cursor-boot "autostart runs cursor-apply --boot (waits for hyprctl, retries, logs to the journal)"; else bad cursor-boot "hyprland.lua must run cursor-apply --boot, not a bare hyprctl setcursor"; fi
if grep -q 'Everforest-Cursor' "$DOTFILES/.config/hypr/hyprland.lua"; then ok cursor-env "hyprland.lua selects Everforest-Cursor when installed, Bibata otherwise"; else bad cursor-env "hyprland.lua has no Everforest-Cursor selection"; fi

# ── audio: the lingering user manager starts pipewire + wireplumber before the owner owns seat0 (no /dev/snd ACL): cards can
# stay on profile off. audio-ensure --check = no card off with a usable saved profile, hardware sink + source, default source no monitor
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
  audio_err="$("$DOTFILES/.local/bin/audio-ensure" --check 2>&1)" && ok audio "cards on their saved profiles, hardware sink and source present, default source is a microphone" \
    || bad audio "$(printf '%s' "$audio_err" | paste -sd';' | sed 's/;/; /g') (fix: ~/.local/bin/audio-ensure)"
else
  info audio "PipeWire not reachable from this shell, skipped"
fi
if grep -q 'audio-ensure --boot' "$DOTFILES/.config/hypr/hyprland.lua"; then ok audio-boot "autostart runs audio-ensure --boot (restarts wireplumber once when a card came up on profile off)"; else bad audio-boot "hyprland.lua must run audio-ensure --boot"; fi

# ── palette variant (black | night): link present, generated fragments in sync with the token source ───────────
theme_link="${XDG_STATE_HOME:-$HOME/.local/state}/theme/current"
if [ -f "$theme_link/tokens.json" ] && [ "$(dirname "$(readlink -f "$theme_link")")" = "$DOTFILES/themes/generated" ]; then
  ok theme "variant $(basename "$(readlink -f "$theme_link")") (theme black|night|toggle)"
else
  bad theme "$theme_link is missing or not a generated variant (run: ~/.local/bin/theme init)"
fi
if PYTHONPYCACHEPREFIX=/tmp/pycache python3 "$DOTFILES/themes/palette/render.py" --check >/dev/null 2>&1; then
  ok theme-generated "themes/generated matches themes/palette/everforest.json and templates"
else
  bad theme-generated "stale: run python3 themes/palette/render.py and commit themes/generated"
fi

# ── desktop layer of the palette: app-facing links resolve, no old-palette literals, the unavoidable literals are tokens ──
missing=""
for rel in .config/waybar/theme.css .config/waybar/theme-black.css .config/wofi/theme.css .config/wofi/theme-black.css \
  .config/swayosd/theme.css .config/swayosd/theme-black.css .config/gtk-3.0/theme.css .config/gtk-3.0/theme-black.css \
  .config/gtk-4.0/theme.css .config/gtk-4.0/theme-black.css .config/dunst/dunstrc.d/50-theme.conf \
  .config/dunst/dunstrc.d/40-theme-black.conf .config/btop/themes/everforest-v2.theme .config/qt6ct/colors/everforest.conf; do
  [ -e "$HOME/$rel" ] || missing="$missing $rel"
done
if [ -z "$missing" ]; then ok theme-desktop "waybar, wofi, swayosd, gtk, dunst, btop, qt6ct follow the active variant"; else bad theme-desktop "dangling or missing:$missing (run: ~/.local/bin/theme init, then stow .)"; fi
old_hex='#(d3c6aa|e7dabe|b8ae96|859289|7fbbb3|a7c080|2a3530|1f2a24|141a17|0b0e0d|222a27|3a4440|6b7770|5f875f|83c092|dbbc7f|e69875|e67e80|d699b6|272e33|374145|f85552)'
stray="$(git -C "$DOTFILES" grep -IiE "$old_hex" -- .config ':!.config/nvim' ':!themes' ':!docs' 2>/dev/null | head -3)"
if [ -z "$stray" ]; then ok theme-stray "no old-palette hex in the tracked configs"; else bad theme-stray "$(printf '%s' "$stray" | head -1)"; fi
nvim_ls="$(nvim --headless -u NONE --cmd "set rtp^=$DOTFILES/.config/nvim" +'lua assert(type(require("configs.layout_switch").setup) == "function")' +qa 2>&1)"
if [ -z "$nvim_ls" ]; then ok nvim-layout "nvim layout autoswitch module loads"; else bad nvim-layout "$(printf '%s' "$nvim_ls" | head -1)"; fi
lit="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 -I - "$DOTFILES" <<'PY' 2>&1
import json, re, sys
root = sys.argv[1]
tokens = set()
for v in ("black", "night"):
    tokens |= {c.lower() for c in json.load(open(f"{root}/themes/generated/{v}/tokens.json"))["tokens"].values()}
bad = []
for path, pat in ((".config/waybar/config", r"color='(#[0-9a-fA-F]{6})'"), (".config/waybar/modules.jsonc", r"color='(#[0-9a-fA-F]{6})'"), (".config/workmux/config.yaml", r"fg=(#[0-9a-fA-F]{6})")):
    for hexc in re.findall(pat, open(f"{root}/{path}").read()):
        if hexc.lower() not in tokens:
            bad.append(f"{path} {hexc}")
print(" ".join(bad))
PY
)"
if [ -z "$lit" ]; then ok theme-literals "waybar calendar spans and workmux icons are palette tokens"; else bad theme-literals "not tokens: $lit"; fi

# ── login screen (G1): greetd + Quickshell greeter, tuigreet fallback ───────────
# The repo side is always checked (FAIL). The system side is INFO until the owner switched (greetd enabled); after that a
# missing or drifted install is a FAIL.
greeter_src="$DOTFILES/infrastructure/greetd"
greeter_bad=""
for f in config.toml config-test.toml tuigreet.toml hyprland.lua tmpfiles.conf greeter-session run-qs hypr-login greeter/shell.qml greeter/Greeter.qml greeter/Theme.qml greeter/users.json; do
  [ -r "$greeter_src/$f" ] || greeter_bad="$greeter_bad $f"
done
for f in greeter-session run-qs hypr-login shell-login; do
  { [ -x "$greeter_src/$f" ] && sh -n "$greeter_src/$f" 2>/dev/null; } || greeter_bad="$greeter_bad $f(not executable or syntax)"
done
# the greeter must start /usr/bin/Hyprland itself: start-hyprland restarts a crashed compositor in --safe-mode and never returns
# to greeter-session, so the tuigreet fallback would be skipped
grep -qE '^/usr/bin/Hyprland ' "$greeter_src/greeter-session" 2>/dev/null && ! grep -qE '^[^#]*start-hyprland' "$greeter_src/greeter-session" 2>/dev/null ||
  greeter_bad="$greeter_bad greeter-session(must run /usr/bin/Hyprland directly, not start-hyprland)"
grep -q 'disable_watchdog_warning = true' "$greeter_src/hyprland.lua" 2>/dev/null || greeter_bad="$greeter_bad hyprland.lua(disable_watchdog_warning)"
# greetd runs `sh -c "exec <argv joined by spaces>"`: a session command must be ONE argv element (a script), or its quoting is lost
jq -e '[.sessions[].cmd | length == 1] | all' "$greeter_src/greeter/users.json" >/dev/null 2>&1 ||
  greeter_bad="$greeter_bad users.json(every session cmd must be a single script path: greetd joins the argv with spaces)"
# the PAM service of the sessions must not start with pam_securetty (it fails for root: greetd sets no PAM_TTY)
{ grep -qE '^service = "greetd-login"' "$greeter_src/config.toml" && ! grep -qE '^[^#]*pam_securetty' "$greeter_src/pam/greetd-login"; } 2>/dev/null ||
  greeter_bad="$greeter_bad pam/greetd-login(config.toml service = greetd-login, no pam_securetty)"
# text consoles: both Hyprlands carry the Ctrl+Alt+Fn -> logind SwitchTo binds, and logind can start a getty on TTY2
for f in "$DOTFILES/.config/hypr/hyprland.lua" "$greeter_src/hyprland.lua"; do
  grep -q 'Seat SwitchTo u' "$f" 2>/dev/null || greeter_bad="$greeter_bad ${f##*/}(Ctrl+Alt+Fn VT binds)"
done
if [ -n "$greeter_bad" ]; then
  bad greeter-repo "missing or broken in infrastructure/greetd:$greeter_bad"
elif [ "$(readlink -f "$greeter_src/greeter/Theme.qml")" != "$(readlink -f "$DOTFILES/themes/generated/black/greeter-palette.qml")" ]; then
  bad greeter-repo "greeter/Theme.qml is not a link to themes/generated/black/greeter-palette.qml"
elif GREETER_ROOT="$greeter_src" Hyprland --verify-config -c "$greeter_src/hyprland.lua" 2>&1 | grep -q '^config ok'; then
  ok greeter-repo "greetd files present, scripts valid, greeter hyprland.lua accepted by Hyprland --verify-config"
else
  bad greeter-repo "Hyprland --verify-config rejects infrastructure/greetd/hyprland.lua"
fi
greeter_report() { # greeter_report <name> <detail>: INFO before the switch, FAIL after it
  if [ "$greeter_on" = 1 ]; then bad "$1" "$2"; else info "$1" "$2"; fi
}
greeter_on=0
if systemctl is-enabled greetd.service >/dev/null 2>&1; then greeter_on=1; fi
if [ "$greeter_on" = 1 ]; then
  ok greeter-enabled "greetd.service is enabled (login screen active from the next boot)"
else
  info greeter-enabled "greetd not enabled: still the tty1 login (sudo ~/dotfiles/apply-system.sh --only greeter, then reboot)"
fi
if [ "$greeter_on" = 1 ] && systemctl is-enabled getty@tty1.service >/dev/null 2>&1; then
  bad greeter-getty "greetd and getty@tty1 are both enabled (rollback half-done?): sudo systemctl disable getty@tty1"
fi
# the rescue console (Ctrl+Alt+F2): logind starts autovt@tty2 (an alias of getty@) when VT2 gets switched to
tty_bad=""
systemctl cat autovt@tty2.service >/dev/null 2>&1 || tty_bad="autovt@.service alias is missing, logind cannot start a getty on VT2 (sudo ln -s /usr/lib/systemd/system/getty@.service /etc/systemd/system/autovt@.service)"
[ "$(systemctl is-enabled getty@tty2.service 2>/dev/null)" = masked ] && tty_bad="${tty_bad:+$tty_bad; }getty@tty2 is masked"
nautovt="$(cat /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null | sed -n 's/^NAutoVTs=//p' | tail -n 1)"
[ "${nautovt:-6}" = 0 ] && tty_bad="${tty_bad:+$tty_bad; }logind NAutoVTs=0 (no getty on VT2)"
if [ -z "$tty_bad" ]; then ok tty-console "logind can start a getty on TTY2 (autovt@ alias present, not masked)"; else bad tty-console "$tty_bad"; fi
missing_pkgs=""
for p in greetd greetd-tuigreet quickshell; do pacman -Q "$p" >/dev/null 2>&1 || missing_pkgs="$missing_pkgs $p"; done
if [ -z "$missing_pkgs" ]; then
  ok greeter-packages "greetd, greetd-tuigreet, quickshell installed"
else
  greeter_report greeter-packages "not installed:$missing_pkgs (sudo ~/dotfiles/apply-system.sh --only greeter)"
fi
drift=""
n_files=0
users_rendered="$(mktemp)"
sed "s|@OWNER@|$USER|g" "$greeter_src/greeter/users.json" >"$users_rendered"   # users.json keeps @OWNER@ in the repo
while read -r src dest; do
  n_files=$((n_files + 1))
  cmp -s "$src" "$dest" 2>/dev/null || drift="$drift ${dest#/}"
done < <(
  printf '%s %s\n' "$greeter_src/config.toml" /etc/greetd/config.toml "$greeter_src/config-test.toml" /etc/greetd/config-test.toml \
    "$greeter_src/tuigreet.toml" /etc/greetd/tuigreet.toml "$greeter_src/hyprland.lua" /etc/greetd/hyprland.lua \
    "$DOTFILES/.config/hypr/monitors.lua" /etc/greetd/monitors.lua "$greeter_src/greeter-session" /usr/local/lib/greeter/greeter-session \
    "$greeter_src/run-qs" /usr/local/lib/greeter/run-qs "$greeter_src/hypr-login" /usr/local/bin/hypr-login \
    "$greeter_src/shell-login" /usr/local/bin/shell-login "$greeter_src/pam/greetd-login" /etc/pam.d/greetd-login
  printf '%s %s\n' "$greeter_src/tmpfiles.conf" /etc/tmpfiles.d/greeter.conf "$users_rendered" /etc/greetd/greeter/users.json
  for f in "$greeter_src"/greeter/*.qml; do printf '%s %s\n' "$f" "/etc/greetd/greeter/$(basename "$f")"; done
)
rm -f -- "$users_rendered"
if [ -z "$drift" ]; then
  ok greeter-files "$n_files installed files match the repo (incl. monitors.lua and the black palette)"
else
  # shellcheck disable=SC2086
  greeter_report greeter-files "$(echo $drift | wc -w) of $n_files differ or are missing, first: $(echo $drift | cut -d' ' -f1-2) (sudo ~/dotfiles/apply-system.sh --only greeter)"
fi
if [ "$greeter_on" = 1 ]; then
  greeter_log=/var/lib/greeter/state/greeter.log
  if [ -r "$greeter_log" ]; then
    if grep -aq 'ERROR' "$greeter_log"; then bad greeter-log "ERROR lines in $greeter_log"; else ok greeter-log "last greeter log has no ERROR"; fi
  else
    info greeter-log "$greeter_log is not readable by $USER (sudo grep ERROR it)"
  fi
fi

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
