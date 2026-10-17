#!/usr/bin/env bash
# dotfiles doctor: asserts that the approved workstation state stays in place. Read-only, no sudo.
#   ./doctor.sh              print PASS/FAIL lines and a summary (exit 1 when anything failed)
#   ./doctor.sh --fails      print only the failures
# Repo-only (listed in .stow-local-ignore). Declined items (restic, keyring, ...) are intentionally not checked.
set -u

# Immune to concurrent edits: bash reads a script incrementally, so a commit that rewrites this file during a run breaks it
# mid-way ("syntax error near unexpected token"). Run from a private copy (0700 temp dir, removed afterwards); DOCTOR_SELF is
# the original path, used for the repo lookups. Falls through to running in place when the copy cannot be made.
if [ -z "${DOCTOR_SELF:-}" ]; then
  DOCTOR_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
  if _dtmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor.XXXXXX" 2>/dev/null)" && install -m 0700 "$DOCTOR_SELF" "$_dtmp/doctor.sh"; then
    export DOCTOR_SELF
    _drc=0
    bash "$_dtmp/doctor.sh" "$@" || _drc=$?
    rm -rf "$_dtmp"
    exit "$_drc"
  fi
fi

DOTFILES="$(cd "$(dirname "$DOCTOR_SELF")" && pwd)"
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

# ── TLP power profiles (62-power.conf: every key for all three tlp-pd profiles) ─
# performance -> *_ON_AC, balanced -> *_ON_BAT, power-saver -> *_ON_SAV. The installed copy must equal the repo file (INFO while
# the owner has not applied it: the old copy has no CPU_BOOST_ON_AC), and the live boost / EPP / platform profile must match the
# active tlp-pd profile. Platform profile mismatch is INFO only (Fn+Q changes it behind TLP until the next TLP run).
tlp_repo="$DOTFILES/infrastructure/tlp"
tlp_inst=/etc/tlp.d/62-power.conf
tlp_val() { sed -n "s/^$2=//p" "$1" | tail -1; } # tlp_val FILE KEY
if [ ! -r "$tlp_inst" ]; then
  info tlp-power "$tlp_inst not installed (sudo ~/dotfiles/apply-system.sh --only config)"
elif ! cmp -s "$tlp_repo/62-power.conf" "$tlp_inst" || ! cmp -s "$tlp_repo/61-battery-care.conf" /etc/tlp.d/61-battery-care.conf; then
  if grep -q '^CPU_BOOST_ON_AC=' "$tlp_inst"; then
    bad tlp-power "/etc/tlp.d/6[12]-*.conf differ from infrastructure/tlp (sudo ~/dotfiles/apply-system.sh --only config)"
  else
    info tlp-power "old /etc/tlp.d/62-power.conf installed (no CPU_BOOST_ON_AC, boost stays off on AC after battery): sudo ~/dotfiles/apply-system.sh --only config"
  fi
else
  tlp_missing=""
  for sfx in AC BAT SAV; do
    for k in PLATFORM_PROFILE CPU_ENERGY_PERF_POLICY CPU_BOOST; do
      [ -n "$(tlp_val "$tlp_repo/62-power.conf" "${k}_ON_$sfx")" ] || tlp_missing="$tlp_missing ${k}_ON_$sfx"
    done
  done
  tlp_prof="$(tlpctl get 2>/dev/null)"
  case "$tlp_prof" in performance) sfx=AC ;; balanced) sfx=BAT ;; power-saver) sfx=SAV ;; *) sfx="" ;; esac
  if [ -n "$tlp_missing" ]; then
    bad tlp-power "repo 62-power.conf lacks:$tlp_missing"
  elif [ -z "$sfx" ]; then
    ok tlp-power "installed copy equals the repo; active tlp-pd profile unknown (tlpctl get: '${tlp_prof:-none}'), live values not checked"
  else
    want_pp="$(tlp_val "$tlp_repo/62-power.conf" PLATFORM_PROFILE_ON_$sfx)"
    want_epp="$(tlp_val "$tlp_repo/62-power.conf" CPU_ENERGY_PERF_POLICY_ON_$sfx)"
    want_boost="$(tlp_val "$tlp_repo/62-power.conf" CPU_BOOST_ON_$sfx)"
    have_pp="$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
    have_boost="$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
    have_epp="$(cat /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"
    have_dyn="$(cat /sys/devices/system/cpu/amd_pstate/dynamic_epp 2>/dev/null)"
    tlp_bad=""
    [ -z "$have_boost" ] || [ "$have_boost" = "$want_boost" ] || tlp_bad="$tlp_bad boost=$have_boost(want $want_boost)"
    [ -z "$have_epp" ] || [ "$have_epp" = "$want_epp" ] || tlp_bad="$tlp_bad epp='$have_epp'(want $want_epp)"
    [ -z "$have_dyn" ] || [ "$have_dyn" = disabled ] || tlp_bad="$tlp_bad dynamic_epp=$have_dyn(want disabled)"
    if [ -n "$tlp_bad" ]; then
      bad tlp-power "profile $tlp_prof:$tlp_bad (run: sudo tlp start)"
    elif [ -n "$have_pp" ] && [ "$have_pp" != "$want_pp" ]; then
      ok tlp-power "profile $tlp_prof: boost $have_boost, EPP $have_epp as configured"
      info tlp-platform "platform profile is $have_pp, the config says $want_pp for $tlp_prof (Fn+Q changes it until the next TLP run)"
    else
      ok tlp-power "profile $tlp_prof: boost $have_boost, EPP $have_epp, platform ${have_pp:-n/a} as configured; dynamic_epp ${have_dyn:-n/a}"
    fi
  fi
fi

# ── network exposure (apply-system.sh --only net: ufw default deny, LLMNR off, v2rayA on loopback) ─
# INFO until the section ran (marker /etc/ufw/.dotfiles-net), then FAIL on: firewall not enabled / not default-deny incoming /
# IPv6 off, a drop-in that differs from infrastructure/net, a non-loopback listener that infrastructure/net/listeners.allow does
# not list (`ss -lntu` as the owner), an ufw allow rule that ufw-rules.conf does not account for. The rule set itself is only
# readable by root: `sudo ufw status verbose` shows the live state.
net_dir="$DOTFILES/infrastructure/net"
net_unlisted="$("$net_dir/exposure-check.sh" listeners 2>/dev/null | paste -sd' ' -)"
if [ ! -e /etc/ufw/.dotfiles-net ]; then
  info net-exposure "firewall section not applied yet (sudo ~/dotfiles/apply-system.sh --only net); unlisted non-loopback listeners now: ${net_unlisted:-none}"
else
  net_bad=""
  grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null || net_bad="$net_bad; ufw.conf ENABLED is not yes"
  systemctl is-active --quiet ufw.service || net_bad="$net_bad; ufw.service is not active (sudo systemctl enable --now ufw.service, or sudo ./apply-system.sh --only net)"
  systemctl is-enabled --quiet ufw.service || net_bad="$net_bad; ufw.service is not enabled (no firewall after a reboot; sudo systemctl enable --now ufw.service)"
  grep -qx 'DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw 2>/dev/null || net_bad="$net_bad; incoming is not default deny"
  grep -qx 'DEFAULT_OUTPUT_POLICY="ACCEPT"' /etc/default/ufw 2>/dev/null || net_bad="$net_bad; outgoing is not default allow"
  grep -qx 'IPV6=yes' /etc/default/ufw 2>/dev/null || net_bad="$net_bad; IPv6 rules are off"
  cmp -s "$net_dir/10-no-llmnr.conf" /etc/systemd/resolved.conf.d/10-no-llmnr.conf 2>/dev/null || net_bad="$net_bad; LLMNR drop-in missing or differs"
  if [ -e /usr/lib/systemd/system/v2raya.service ] && ! cmp -s "$net_dir/v2raya-loopback.conf" /etc/systemd/system/v2raya.service.d/10-loopback.conf 2>/dev/null; then
    net_bad="$net_bad; v2raya loopback drop-in missing or differs"
  fi
  [ -z "$net_unlisted" ] || net_bad="$net_bad; unlisted listeners: $net_unlisted"
  net_stale="$("$net_dir/exposure-check.sh" stale-rules 2>/dev/null | sed 's/^[^:]*: -A ufw6\?-user-[a-z]* //; s/ -j ACCEPT$//' | sort -u | paste -sd',' -)"
  [ -z "$net_stale" ] || net_bad="$net_bad; ufw allow rules outside ufw-rules.conf: $net_stale (sudo ufw status numbered; sudo ufw delete N)"
  if [ -z "$net_bad" ]; then
    ok net-exposure "ufw active, deny incoming, IPv6 on; no unlisted non-loopback listener; LLMNR off"
  else
    bad net-exposure "${net_bad#; }"
  fi
fi

if net_t="$("$DOTFILES/infrastructure/tests/net/run.sh" 2>&1)"; then ok net-tests "offline tests: $(printf '%s' "$net_t" | tail -1)"; else bad net-tests "$(printf '%s' "$net_t" | grep -m1 '^FAIL') (infrastructure/tests/net/run.sh)"; fi

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
# BW1: the per-session bw server of vault-bw.py (bw serve on a unix socket): never a TCP listener, socket 0600 in a 0700 directory
# owned by the owner, unreachable for the other users of this machine (managed users, service users, greeter)
bw_run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vault"
bw_tcp="$(ss -ltnpH 2>/dev/null | grep -E '"bw"|[:.]8087[[:space:]]' | head -2 | paste -sd';' || true)"
bw_bad=""
[ -n "$bw_tcp" ] && bw_bad="TCP listener: $bw_tcp"
if [ -S "$bw_run/bw.sock" ]; then
  bw_mode="$(stat -c '%a %U' "$bw_run/bw.sock" 2>/dev/null)"
  bw_dir="$(stat -c '%a %U' "$bw_run" 2>/dev/null)"
  [ "$bw_mode" = "600 $(id -un)" ] || bw_bad="$bw_bad; socket is '$bw_mode', want '600 $(id -un)'"
  [ "$bw_dir" = "700 $(id -un)" ] || bw_bad="$bw_bad; $bw_run is '$bw_dir', want '700 $(id -un)'"
  for bw_u in $(awk -F'\t' '!/^[[:space:]]*#/ && NF {print $1}' "$DOTFILES/infrastructure/users/managed.tsv" 2>/dev/null) tgconfirm aimcp greeter; do
    id -u "$bw_u" >/dev/null 2>&1 || continue
    bw_reach="$(python3 -I "$DOTFILES/infrastructure/users/acl-reach.py" "$(id -u "$bw_u")" "$(dirname "$bw_run")" 2>/dev/null | grep 'vault/bw.sock' | head -1)"
    [ -n "$bw_reach" ] && bw_bad="$bw_bad; $bw_u can reach it ($bw_reach)"
  done
  if [ -n "$bw_bad" ]; then bad vault-bw-serve "${bw_bad#; }"; else ok vault-bw-serve "bw serve on $bw_run/bw.sock: socket 600, dir 700, no TCP listener, no other user can reach it"; fi
elif [ -n "$bw_bad" ]; then
  bad vault-bw-serve "${bw_bad#; }"
else
  info vault-bw-serve "not running (starts on the first Trash / edit / new action after the bw unlock; no TCP listener)"
fi
# V1c: generated layout twins are current (tmux/rofi depend on running tools and are skipped by `layout.py check`)
if lay_out="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 "$DOTFILES/.config/layout/layout.py" check 2>&1)"; then ok layout-gen "generated ua/ru twins are current (layout.py check)"; else bad layout-gen "stale: $(printf '%s' "$lay_out" | head -1) (layout.py gen)"; fi
# K4: offline test of the ghostty twin generator (fixture defaults and config, no ghostty needed)
if [ -x "$DOTFILES/infrastructure/tests/layout/run.sh" ]; then
  if lt_out="$("$DOTFILES/infrastructure/tests/layout/run.sh" 2>&1)"; then ok layout-tests "ghostty twin generator: $(printf '%s' "$lt_out" | tail -1)"; else bad layout-tests "$(printf '%s' "$lt_out" | grep -m1 '^FAIL') (infrastructure/tests/layout/run.sh)"; fi
else
  bad layout-tests "infrastructure/tests/layout/run.sh missing"
fi
# K4: ghostty matches Ctrl+Shift+<letter> by the produced character, so every such keybind needs a physical-key twin in the LIVE config
if command -v ghostty >/dev/null 2>&1; then
  gh_keys="$(ghostty +list-keybinds 2>/dev/null)"
  gh_miss=""
  for gh_k in ctrl+shift+key_a ctrl+shift+key_c ctrl+shift+key_v ctrl+shift+key_n ctrl+shift+key_t ctrl+shift+key_w ctrl+slash alt+key_b; do
    printf '%s\n' "$gh_keys" | grep -q "^keybind = $gh_k=" || gh_miss="$gh_miss $gh_k"
  done
  if [ -z "$gh_miss" ]; then ok ghostty-twins "ghostty has the physical-key twins (Ctrl+Shift+C/V/N/T/W/A, Ctrl+/, Alt+letter) in its live keybinds"; else bad ghostty-twins "missing from ghostty +list-keybinds:$gh_miss (layout.py gen ghostty; is layout-keys.conf included by ghostty/config?)"; fi
fi
# OB1: Obsidian config lives in apps/obsidian/vault-config (every vault's .obsidian links there), plugins are pinned + hash-verified,
# the Everforest snippet follows the theme link, the vimrc is linked (apps/obsidian/apply.sh)
if [ -x "$DOTFILES/apps/obsidian/apply.sh" ]; then
  obs_cfg="$DOTFILES/apps/obsidian/vault-config"
  obs_dry="$("$DOTFILES/apps/obsidian/apply.sh" --dry-run 2>&1)"
  if printf '%s' "$obs_dry" | grep -q 'no vault found'; then info obsidian "no Obsidian vault registered yet (apps/obsidian/apply.sh --vault DIR)"
  else
    if printf '%s' "$obs_dry" | grep -q 'would: move the real\|would: link .obsidian\|would: re-point'; then
      bad obsidian "a vault's .obsidian does not link to $obs_cfg (apps/obsidian/apply.sh, Obsidian closed)"
    else ok obsidian "every vault's .obsidian links to apps/obsidian/vault-config"; fi
    if obs_pl="$("$DOTFILES/apps/obsidian/plugins.sh" check "$obs_cfg" 2>&1)"; then ok obsidian-plugins "pinned plugins present, sha256 match plugins.tsv"
    else bad obsidian-plugins "$(printf '%s' "$obs_pl" | head -1 | sed 's/^ *//') (apps/obsidian/plugins.sh install)"; fi
    if [ -s "$obs_cfg/snippets/everforest.css" ] && grep -q 'Everforest' "$obs_cfg/snippets/everforest.css" \
       && [ "$(readlink -f "$obs_cfg/snippets/everforest.css")" = "$(readlink -f "$HOME/.local/state/theme/current/obsidian.css")" ]; then
      ok obsidian-snippet "snippet everforest.css resolves to the active variant ($(basename "$(readlink -f "$HOME/.local/state/theme/current")"))"
    else bad obsidian-snippet "snippets/everforest.css missing or not the active theme's obsidian.css (apps/obsidian/apply.sh)"; fi
    if jq -e 'index("everforest")' <(jq '.enabledCssSnippets' "$obs_cfg/appearance.json") >/dev/null 2>&1 \
       && jq -e 'index("obsidian-vimrc-support")' "$obs_cfg/community-plugins.json" >/dev/null 2>&1 \
       && jq -e . "$obs_cfg"/*.json >/dev/null 2>&1; then ok obsidian-config "vault-config JSON valid, snippet and Vimrc Support enabled"
    else bad obsidian-config "vault-config/*.json invalid or everforest / obsidian-vimrc-support not enabled"; fi
    if printf '%s' "$obs_dry" | grep -q 'would: link .obsidian.vimrc\|would: write vault-config/obsidian.vimrc'; then bad obsidian-vimrc "vimrc link missing or stale (apps/obsidian/apply.sh)"
    else ok obsidian-vimrc "vault .obsidian.vimrc links to the current generated vimrc"; fi
  fi
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
# ── M1: MCP gateway (mcp-proxy, user service), desktop-ro, chrome-devtools pair, Telegram (root part) ───────────────────────
mcp_state="${XDG_STATE_HOME:-$HOME/.local/state}/mcp"
if [ -x "$HOME/.local/bin/mcp-gateway" ]; then
  if mcp_inst="$("$HOME/.local/bin/mcp-install" --check 2>&1)"; then ok mcp-install "pinned mcp-proxy, desktop-ro venv and chrome-devtools-mcp are installed and current"
  else bad mcp-install "$(printf '%s' "$mcp_inst" | grep -m1 'NOT\|failed\|MISMATCH') (run: mcp-install)"; fi
  if mcp_st="$("$HOME/.local/bin/mcp-gateway" status 2>&1)"; then ok mcp-gateway "$(printf '%s' "$mcp_st" | sed -n 's/^health: *//p'); served: $(printf '%s' "$mcp_st" | sed -n 's/^served: *//p')"
  else bad mcp-gateway "gateway is down or unhealthy: $(printf '%s' "$mcp_st" | head -2 | tr '\n' ' ')(systemctl --user enable --now mcp-gateway; mcp-gateway logs)"; fi
  if [ "$(stat -c %a "$mcp_state/gateway.token" 2>/dev/null)" = 600 ] && [ "$(stat -c %a "$mcp_state" 2>/dev/null)" = 700 ]; then ok mcp-token "gateway token is a 0600 file in a 0700 directory ($mcp_state)"
  else bad mcp-token "gateway token missing or too open (mcp-gateway token ensure; chmod 600 $mcp_state/gateway.token)"; fi
  mcp_addr="$(jq -r '.mcpProxy.addr' "$HOME/.config/mcp/gateway.json" 2>/dev/null)"
  mcp_listen="$(ss -ltnH "sport = :${mcp_addr##*:}" 2>/dev/null | awk '{print $4}')"
  if [ -n "$mcp_addr" ] && [ -n "$mcp_listen" ] && [ "$mcp_listen" = "$mcp_addr" ]; then ok mcp-bind "gateway listens on $mcp_addr only (loopback)"
  else bad mcp-bind "gateway is not listening on a loopback-only address (config: ${mcp_addr:-none})"; fi
  if jq -e '.mcpServers | to_entries | all(.value.options.toolFilter? == null or .value.options.toolFilter.mode == "allow")' "$HOME/.config/mcp/gateway.json" >/dev/null 2>&1 \
    && ! jq -r '.mcpServers.telegram.options.toolFilter.list[]' "$HOME/.config/mcp/gateway.json" 2>/dev/null | grep -qE '^(send|reply|edit|delete|forward|mark|save|upload|download|press|join|leave|invite|ban|unban|pin|unpin|set_|create|update|promote|demote|add_|remove|block|unblock|mute|unmute|archive|unarchive|import|export|clear|toggle|vote|subscribe|enable|disable)'; then
    ok mcp-toolfilter "telegram toolFilter is an allow list without send/edit/delete/mark tools"
  else bad mcp-toolfilter "gateway.json: telegram toolFilter missing, not an allow list, or exposes a write tool"; fi
  if [ ! -e "$DOTFILES/.config/mcphub" ] && ! grep -rqiE 'mcphub\.nvim|plugins\.ai\.mcphub' "$DOTFILES/.config/nvim/lua" 2>/dev/null \
    && ! grep -qE 'mcp-hub@|37373' "$DOTFILES/install.sh" 2>/dev/null \
    && ! ss -ltn 'sport = :37373' 2>/dev/null | grep -q LISTEN; then
    ok mcp-hub-gone "mcphub is gone: no .config/mcphub, no mcphub.nvim, nothing on :37373"
    [ -d /srv/mcphub ] && info mcp-hub-srv "/srv/mcphub still exists (removed by: sudo ./apply-system.sh --only mcp)"
  else bad mcp-hub-gone "mcphub leftovers: .config/mcphub, mcphub.nvim, install.sh or a listener on :37373"; fi
  mcp_claude="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/}${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && mcp_claude="$CLAUDE_CONFIG_DIR/.claude.json"
  if [ -e "$mcp_state/mcp-added" ] && jq -e '.mcpServers["desktop-ro"].headersHelper and (.mcpServers.mcphub | not)' "$mcp_claude" >/dev/null 2>&1; then
    ok mcp-add "mcp-add was run: desktop-ro is registered in Claude Code, mcphub is gone"
  elif jq -e '.mcpServers.mcphub' "$mcp_claude" >/dev/null 2>&1 || [ ! -e "$mcp_state/mcp-added" ]; then
    info mcp-add "run once (it edits Claude Code and Codex config): mcp-add"
  else bad mcp-add "Claude Code has no desktop-ro entry although mcp-add ran (rerun: mcp-add)"; fi
  if mcp_test="$("$DOTFILES/infrastructure/tests/mcp/run.sh" --quick 2>&1)"; then ok mcp-test "offline tests: $(printf '%s' "$mcp_test" | tail -1 | sed 's/^mcp tests: //')"
  else bad mcp-test "offline test failed (infrastructure/tests/mcp/run.sh): $(printf '%s' "$mcp_test" | grep -m1 '^FAIL')"; fi
  # Telegram MCP (root part: sudo ./apply-system.sh --only users,mcp; then mcp-telegram-setup): INFO until applied, FAIL on drift
  tg_dir="$DOTFILES/infrastructure/mcp/telegram"
  if [ -x /usr/local/lib/telegram-mcp/run ] && [ -r /etc/systemd/system/telegram-mcp.service ]; then
    tg_drift=""
    for tg_f in run serve.py creds-install login.py; do cmp -s "$tg_dir/$tg_f" "/usr/local/lib/telegram-mcp/$tg_f" || tg_drift="$tg_drift $tg_f"; done
    for tg_f in telegram-mcp.service telegram-whisper.service telegram-whisper-proxy.service telegram-whisper-proxy.socket; do cmp -s "$tg_dir/$tg_f" "/etc/systemd/system/$tg_f" || tg_drift="$tg_drift $tg_f"; done
    if [ -z "$tg_drift" ]; then ok mcp-tg-files "telegram-mcp scripts and units match the repo"; else bad mcp-tg-files "installed files differ from the repo:$tg_drift (sudo ./apply-system.sh --only mcp)"; fi
  else
    info mcp-tg-files "Telegram service not installed yet: sudo ./apply-system.sh --only users,mcp"
  fi
  if getent passwd aimcp >/dev/null; then
    aimcp_home="$(getent passwd aimcp | cut -d: -f6)"
    if [ "$(getent passwd aimcp | cut -d: -f7)" = /usr/bin/nologin ] && [ "$(stat -c %a "$aimcp_home" 2>/dev/null)" = 700 ] && ! id -nG aimcp | tr ' ' '\n' | grep -qxE 'wheel|docker|sudo'; then
      ok mcp-aimcp "aimcp: nologin, home 0700, not in wheel/docker"
    else bad mcp-aimcp "aimcp must have shell nologin, home 0700 and no wheel/docker membership"; fi
    if sudo -k -n -u aimcp true >/dev/null 2>&1; then bad mcp-aimcp-sudo "the owner can reach aimcp without a password (sudo -k -n -u aimcp works)"
    elif machinectl --no-ask-password --quiet shell aimcp@ /usr/bin/true >/dev/null 2>&1; then bad mcp-aimcp-sudo "machinectl shell aimcp@ needs no password"
    else ok mcp-aimcp-sudo "aimcp is reachable only with a sudo password (no passwordless sudo -u / machinectl)"; fi
  else
    info mcp-aimcp "service user aimcp does not exist yet: sudo ./apply-system.sh --only users,mcp"
  fi
  tg_state="$(systemctl is-active telegram-mcp.service 2>/dev/null)"
  # `systemctl show -p LoadCredentialEncrypted` prints "[unprintable]" (credential paths are hidden), so count the directives in the
  # unit file and its drop-ins instead (5 base credentials, plus the 2 send credentials of send.conf once sending is set up)
  tg_creds="$(systemctl cat telegram-mcp.service 2>/dev/null | grep -c '^LoadCredentialEncrypted=')"
  case "$tg_state" in
    active) if [ "$tg_creds" -ge 5 ]; then ok mcp-telegram "telegram-mcp.service is active with $tg_creds encrypted credentials (TPM2 + host key)"; else bad mcp-telegram "telegram-mcp.service is active but has $tg_creds LoadCredentialEncrypted entries"; fi ;;
    failed) bad mcp-telegram "telegram-mcp.service failed: journalctl -u telegram-mcp -n 40 (mcp-telegram-setup status)" ;;
    *) info mcp-telegram "telegram-mcp.service is $tg_state: one-time setup pending (mcp-telegram-setup)" ;;
  esac
  # Telegram sending (M1-send): the repo-side facts always, the machine-side ones once the root part ran (INFO until then)
  snd_bad=""
  jq -e '.mcpServers["telegram-send"].options.toolFilter | .mode == "allow" and ((.list | sort) == ["send_message", "status"])' "$HOME/.config/mcp/gateway.json" >/dev/null 2>&1 \
    || snd_bad="$snd_bad; gateway.json: telegram-send toolFilter is not an allow list of exactly send_message + status"
  grep -qs 'telegram-send' "${CODEX_HOME:-$HOME/.codex}/config.toml" && snd_bad="$snd_bad; telegram-send is registered for Codex (Codex has no permission rules: mcp-add removes it)"
  for snd_f in /etc/credstore.encrypted/telegram-mcp.send_token /etc/credstore.encrypted/tgconfirm.send_token; do
    [ -r "$snd_f" ] && snd_bad="$snd_bad; $snd_f is readable by $USER"
  done
  find "$mcp_state" -maxdepth 1 -iname '*send*token*' 2>/dev/null | grep -q . && snd_bad="$snd_bad; a send token file exists in $mcp_state"
  if [ -r /etc/systemd/system/tgconfirm.service ]; then
    snd_drift=""
    for snd_f in broker.py popup.py; do cmp -s "$DOTFILES/infrastructure/mcp/confirm/$snd_f" "/usr/local/lib/tgconfirm/$snd_f" || snd_drift="$snd_drift $snd_f"; done
    cmp -s "$DOTFILES/infrastructure/mcp/confirm/tgconfirm.service" /etc/systemd/system/tgconfirm.service || snd_drift="$snd_drift tgconfirm.service"
    cmp -s "$tg_dir/send.conf" /usr/local/lib/telegram-mcp/send.conf || snd_drift="$snd_drift send.conf"
    if [ -z "$snd_drift" ]; then ok mcp-send-files "tgconfirm broker, popup, unit and send.conf match the repo"; else bad mcp-send-files "installed files differ from the repo:$snd_drift (sudo ./apply-system.sh --only mcp)"; fi
    if getent passwd tgconfirm >/dev/null; then
      getfacl -p "$HOME" 2>/dev/null | grep -q 'tgconfirm' && snd_bad="$snd_bad; tgconfirm has an ACL entry on $HOME"
      # everything tgconfirm can reach in the runtime dir, by the kernel's rules (named ACL entry, else the OTHER bits): only the Wayland socket
      snd_acl="$(python3 -I "$DOTFILES/infrastructure/users/acl-reach.py" "$(id -u tgconfirm)" "/run/user/$(id -u)" --allow "$(basename "${WAYLAND_DISPLAY:-wayland-1}")" 2>&1 | head -4 | paste -sd';')"
      [ -n "$snd_acl" ] && snd_bad="$snd_bad; tgconfirm can reach in /run/user/$(id -u) (named ACL or other bits): $snd_acl (only the Wayland socket is allowed; run: usr clipboard-acl)"
      sudo -k -n -u tgconfirm true >/dev/null 2>&1 && snd_bad="$snd_bad; the owner can reach tgconfirm without a password"
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
      if snd_wl="$(python3 -I "$DOTFILES/infrastructure/mcp/confirm/broker.py" --check-wayland 2>&1)"; then ok mcp-send-wayland "the broker's socket check accepts the live session ($snd_wl)"
      else bad mcp-send-wayland "the broker's compositor check refuses the live session: $snd_wl"; fi
    fi
    snd_tok="$mcp_state/telegram.token" snd_restart=""
    snd_state="$(systemctl is-active telegram-mcp.service 2>/dev/null)"
    if [ -r "$snd_tok" ] && [ "$snd_state" != inactive ] && [ "$snd_state" != failed ]; then
      # a restart (send-chats, creds-install) makes the port answer 000 for a few seconds: retry over ~5 s before judging
      snd_code=000 snd_try=0
      while [ "$snd_try" -lt 6 ]; do
        snd_code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' -X POST -H @<(printf 'Authorization: Bearer %s' "$(cat "$snd_tok")") -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8765/x-send 2>/dev/null)"
        case "$snd_code" in 401 | 503) break ;; esac
        snd_try=$((snd_try + 1))
        sleep 1
      done
      case "$snd_code" in
        401 | 503) ;;
        000 | "") snd_state="$(systemctl is-active telegram-mcp.service 2>/dev/null)"
          if [ "$snd_state" = activating ] || [ "$snd_state" = reloading ]; then snd_restart="telegram-mcp.service is restarting ($snd_state), the /x-send probe was skipped"
          else snd_bad="$snd_bad; POST /x-send did not answer for 5 s (telegram-mcp.service is $snd_state)"; fi ;;
        *) snd_bad="$snd_bad; POST /x-send with the MCP token answered $snd_code (expected 401, or 503 while sending is not set up)" ;;
      esac
    fi
    if [ -z "$snd_bad" ] && [ -n "$snd_restart" ]; then info mcp-send-route "$snd_restart; the other route checks hold (run doctor again in a few seconds)"
    elif [ -z "$snd_bad" ]; then ok mcp-send-route "/x-send refuses the MCP token, telegram-send is Claude-only with an allow list of send_message + status, no send credential readable, tgconfirm has only the Wayland socket"
    else bad mcp-send-route "${snd_bad#; }"; fi
  else
    info mcp-send-files "tgconfirm is not installed yet: sudo ./apply-system.sh --only users,mcp, then mcp-telegram-setup send-chats"
    if [ -z "$snd_bad" ]; then info mcp-send-route "sending is not set up yet; the repo-side rules hold (telegram-send allow list, not in Codex, no send credential readable)"
    else bad mcp-send-route "${snd_bad#; }"; fi
  fi
  if "$HOME/.local/bin/mcp-guard" --check >/dev/null 2>&1; then ok mcp-guard "Claude Code denies wtype, wlrctl, hyprd, hyprctl eval/dispatch and grim to the agents' Bash"
  else info mcp-guard "deny rules for key injection and capture are not in Claude Code's settings yet: mcp-guard (mcp-add runs it)"; fi
  # a new compositor socket inherits the runtime dir's default ACL (u:tgconfirm:---): the popup cannot connect until usr clipboard-acl
  # ran again. The Hyprland autostart runs it per compositor instance; wayland-acl.path (PathChanged on the runtime dir) is the safety net.
  if systemctl --user is-active wayland-acl.path >/dev/null 2>&1 && systemctl --user is-enabled wayland-acl.path >/dev/null 2>&1; then ok mcp-wayland-acl "wayland-acl.path re-applies the Wayland ACL when a compositor socket appears"
  else info mcp-wayland-acl "wayland-acl.path is not enabled: after a compositor restart the popup fails until usr clipboard-acl runs (stow ., systemctl --user enable --now wayland-acl.path)"; fi
  if wl_out="$("$DOTFILES/infrastructure/tests/wayland-acl/run.sh" 2>&1)"; then ok mcp-wayland-acl-test "wayland-acl.sh picks the session compositor's socket and runs usr clipboard-acl once per socket: $(printf '%s' "$wl_out" | tail -1)"
  else bad mcp-wayland-acl-test "$(printf '%s' "$wl_out" | grep -m1 '^FAIL') (infrastructure/tests/wayland-acl/run.sh)"; fi
  if [ -s /srv/models/ggml-small.bin ]; then ok mcp-whisper "Whisper model shared in /srv/models ($(stat -c %s /srv/models/ggml-small.bin) bytes)"; else info mcp-whisper "no /srv/models/ggml-small.bin yet (sudo ./apply-system.sh --only mcp)"; fi
  if [ -x /usr/bin/chromium ]; then ok mcp-chromium "Chromium for the clean chrome-devtools server is installed"; else info mcp-chromium "chromium not installed: chrome-devtools answers with a stub (sudo ./apply-system.sh --only mcp)"; fi
else
  bad mcp-gateway ".local/bin/mcp-gateway missing (cd ~/dotfiles && stow .)"
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
fi
# gsettings cursor-theme must be the expected theme (Hyprland writes it from XCURSOR_THEME at login; `hyprctl setcursor` writes it too,
# so a test with another theme leaves it behind: only cursor-apply switches the pointer, `cursor-apply --revert` goes back to Bibata)
if command -v gsettings >/dev/null 2>&1; then
  cur_want=Everforest-Cursor
  [ -r "$cur_dir/index.theme" ] || cur_want=Bibata-Modern-Ice
  cur_gs="$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null | tr -d "'")"
  if [ "$cur_gs" = "$cur_want" ]; then ok cursor-gtk "gsettings cursor-theme is $cur_want"; else bad cursor-gtk "gsettings cursor-theme is '$cur_gs', expected $cur_want (run cursor-apply; never switch the pointer with hyprctl setcursor, it writes gsettings)"; fi
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

# audio-mic: the default source must deliver a varying signal (LENOVO 83HY: UCM named the unconnected ACP PDM "Mic1" and the source was a
# constant rail; 51-hda-no-ucm.conf fixes it). 1.5 s are measured, only statistics are printed, no audio is kept.
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
  mic_out="$("$DOTFILES/.local/bin/audio-ensure" --mic 2>&1)"; mic_rc=$?
  case "$mic_rc" in
    0) ok audio-mic "$mic_out" ;;
    1) bad audio-mic "$mic_out (fix: check ~/.config/wireplumber/wireplumber.conf.d/51-hda-no-ucm.conf is linked, systemctl --user restart wireplumber)" ;;
    *) info audio-mic "$mic_out" ;;
  esac
else
  info audio-mic "PipeWire not reachable from this shell, skipped"
fi
check audio-hda-ucm "wireplumber rule turns UCM off for the 83HY HDA card (the built-in mic is the codec's, not the ACP PDM)" \
  "$HOME/.config/wireplumber/wireplumber.conf.d/51-hda-no-ucm.conf missing or not stowed (cd ~/dotfiles && stow .)" \
  grep -q 'api.alsa.use-ucm = false' "$HOME/.config/wireplumber/wireplumber.conf.d/51-hda-no-ucm.conf"

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

# ── U7: managed users (td, yc, later service users), infrastructure/users/managed.tsv ──────────────────────────
# The repo side is always checked (FAIL). The root side (ACL removal, sudoers, polkit, /srv) is INFO until the owner ran
# `sudo ./apply-system.sh --only users` (/srv/dotfiles exists then), after that every missing piece FAILs.
users_lib="$DOTFILES/infrastructure/users/lib.sh"
if [ -r "$users_lib" ]; then
  # shellcheck source=infrastructure/users/lib.sh
  source "$users_lib"
  users_problems="$(managed_validate "$USER")"
  if [ -z "$users_problems" ]; then ok users-registry "managed.tsv is valid: $(managed_users | paste -sd' ' -)"; else bad users-registry "managed.tsv: $(echo "$users_problems" | head -2 | paste -sd';' -)"; fi
  users_on=0
  [ -d /srv/dotfiles ] && users_on=1
  users_report() { # users_report <name> <detail>: INFO before the owner ran the users section, FAIL after it
    if [ "$users_on" = 1 ]; then bad "$1" "$2"; else info "$1" "$2"; fi
  }
  if [ -x "$DOTFILES/.local/bin/usr" ] && [ -x "$HOME/.local/bin/usr" ]; then ok users-usr "usr helper stowed ($("$HOME/.local/bin/usr" list 2>/dev/null | awk 'NR>1{print $1}' | paste -sd' ' -))"; else bad users-usr "\$HOME/.local/bin/usr missing (cd ~/dotfiles && stow .)"; fi
  if [ "$(git -C "$DOTFILES" config core.hooksPath 2>/dev/null)" = .githooks ] && [ -x "$DOTFILES/.githooks/publish" ]; then ok users-hook "git hooks publish the committed state (core.hooksPath = .githooks)"; else bad users-hook "core.hooksPath is not .githooks (git -C ~/dotfiles config core.hooksPath .githooks)"; fi
  if hyprctl binds -j 2>/dev/null | jq -e '.[] | select(.key == "T" and .modmask == 65 and (.description | test("managed user")))' >/dev/null 2>&1; then ok users-bind "SUPER+SHIFT+T opens the user picker (usr menu)"; else bad users-bind "SUPER+SHIFT+T is not the user picker in the live bind table (hyprctl reload)"; fi
  if "$DOTFILES/.config/hub/hub" --list --all 2>/dev/null | grep -q 'usr-menu'; then ok users-hub "hub rows usr-* exist"; else bad users-hub "hub row usr-menu missing (.config/hub/actions.d/u7.tsv)"; fi
  users_log="$(mktemp)"
  if "$DOTFILES/infrastructure/tests/users/run.sh" --quick >"$users_log" 2>&1; then ok users-tests "offline tests: $(tail -1 "$users_log")"; else bad users-tests "$(grep -m1 FAIL "$users_log") (infrastructure/tests/users/run.sh)"; fi
  rm -f "$users_log"
  # no linger, no user services of the interactive users: their windows own their processes
  users_linger=""
  for u in $(managed_users interactive); do [ -e "/var/lib/systemd/linger/$u" ] && users_linger="$users_linger $u"; done
  if [ -z "$users_linger" ]; then ok users-no-linger "no managed interactive user lingers"; else users_report users-no-linger "linger is on for:$users_linger (sudo ./apply-system.sh --only users)"; fi
  # the managed users have no ACL entry on the owner's home (top two levels; the section removes the whole tree)
  users_acl=""
  for u in $(managed_users); do
    getent passwd "$u" >/dev/null || continue
    n=$(find "$HOME" -xdev -maxdepth 2 ! -type l -print0 2>/dev/null | xargs -0 -r getfacl -p -s 2>/dev/null | grep -c "^\(default:\)\?user:$u:")
    [ "$n" -gt 0 ] && users_acl="$users_acl $u($n)"
  done
  if [ -z "$users_acl" ]; then ok users-acl-home "no managed user has an ACL entry on $HOME"; else users_report users-acl-home "ACL entries on $HOME remain for:$users_acl (sudo ./apply-system.sh --only users)"; fi
  # the owner reaches the managed homes
  users_noacl=""
  for u in $(managed_users acl); do
    h=$(getent passwd "$u" | cut -d: -f6)
    [ -n "$h" ] && [ -d "$h" ] || continue
    getfacl -p "$h" 2>/dev/null | grep -q "^user:$USER:rwx" || users_noacl="$users_noacl $u"
  done
  if [ -z "$users_noacl" ]; then ok users-acl-managed "the owner has u:$USER:rwx on the managed homes"; else users_report users-acl-managed "no owner ACL on the home of:$users_noacl (sudo ./apply-system.sh --only users)"; fi
  # passwordless become (sudoers) and terminals (polkit); never root
  users_nosudo=""
  for u in $(managed_users become); do
    getent passwd "$u" >/dev/null || continue
    sudo -n -u "$u" true >/dev/null 2>&1 || users_nosudo="$users_nosudo $u"
  done
  if [ -z "$users_nosudo" ]; then
    if sudo -n -v >/dev/null 2>&1; then ok users-sudoers "sudo -n -u <managed> works (the root check is skipped: a sudo timestamp is valid)"
    elif sudo -n -u root true >/dev/null 2>&1; then bad users-sudoers "sudo -n -u root works without a password: the drop-in is too wide"
    else ok users-sudoers "sudo -n -u <managed> works, root still needs the password"; fi
  else
    users_report users-sudoers "no passwordless sudo -u for:$users_nosudo (sudo ./apply-system.sh --only users)"
  fi
  users_nopk=""
  for u in $(managed_users become); do
    getent passwd "$u" >/dev/null && managed_has "$u" interactive || continue
    machinectl --no-ask-password --quiet shell "$u@" /usr/bin/true >/dev/null 2>&1 || users_nopk="$users_nopk $u"
  done
  if [ -z "$users_nopk" ]; then
    if machinectl --no-ask-password --quiet shell root@ /usr/bin/true >/dev/null 2>&1; then bad users-polkit "machinectl shell root@ needs no authentication: the polkit rule is too wide"
    else ok users-polkit "machinectl shell <managed>@ needs no password, root@ is still refused"; fi
  else
    users_report users-polkit "machinectl shell is not authorised for:$users_nopk (sudo ./apply-system.sh --only users)"
  fi
  # published dotfiles: owned by the owner, current, no secrets
  if [ -d /srv/dotfiles ]; then
    users_srv_bad=""
    [ "$(stat -c %U /srv/dotfiles)" = "$USER" ] || users_srv_bad="$users_srv_bad owner"
    [ -e /srv/dotfiles/private ] && users_srv_bad="$users_srv_bad private/"
    [ -e /srv/dotfiles/env.secret.sh ] && users_srv_bad="$users_srv_bad env.secret.sh"
    [ "$(sed -n 's/^rev=//p' /srv/dotfiles/.published 2>/dev/null)" = "$(git -C "$DOTFILES" rev-parse HEAD)" ] || users_srv_bad="$users_srv_bad stale(usr sync)"
    if [ -z "$users_srv_bad" ]; then ok users-srv-dotfiles "/srv/dotfiles = ~/dotfiles HEAD, owned by $USER, no private/ or env.secret.sh"; else bad users-srv-dotfiles "/srv/dotfiles:$users_srv_bad"; fi
  else
    info users-srv-dotfiles "/srv/dotfiles does not exist yet (sudo ./apply-system.sh --only users)"
  fi
  # profile links of the managed users point at /srv/dotfiles
  users_nolink=""
  for u in $(managed_users profile); do
    h=$(getent passwd "$u" | cut -d: -f6)
    [ -n "$h" ] && [ -d "$h" ] || continue
    [ "$(readlink "$h/.zshrc" 2>/dev/null)" = /srv/dotfiles/.zshrc ] || users_nolink="$users_nolink $u"
  done
  if [ -z "$users_nolink" ]; then ok users-links "profile links of the managed users point into /srv/dotfiles"; else users_report users-links "profile not linked for:$users_nolink (usr link USER)"; fi
  # shared nvim: ready and current (the install runs in the background; INFO while it has not finished)
  if [ -r /srv/nvim-shared/.ready ]; then
    users_nvim_want="$(cat /srv/dotfiles/.config/nvim/lazy-lock.json /srv/dotfiles/.config/nvim/lua/plugins/mason.lua 2>/dev/null | sha256sum | cut -d' ' -f1)"
    if [ "$(sed -n 's/^stamp=//p' /srv/nvim-shared/.ready)" = "$users_nvim_want" ] && [ -r /srv/nvim-shared/mason/bin ] && [ -r /srv/nvim-shared/lazy/lazy.nvim/lua ]; then
      ok users-nvim-shared "/srv/nvim-shared is current ($(du -sh /srv/nvim-shared 2>/dev/null | cut -f1)), readable by everyone"
    else
      info users-nvim-shared "/srv/nvim-shared is older than the nvim pins (usr nvim-sync)"
    fi
  else
    info users-nvim-shared "/srv/nvim-shared is not ready (usr nvim-sync; the users section starts it in the background)"
  fi
  # the clipboard: traverse-only on the runtime dir, rw on the Wayland socket, the other sockets closed
  users_clip=""
  for u in $(managed_users wayland); do
    getent passwd "$u" >/dev/null || continue
    [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] || continue
    [ "$(getfacl -p "$XDG_RUNTIME_DIR" 2>/dev/null | grep "^user:$u:")" = "user:$u:--x" ] || users_clip="$users_clip $u(dir)"
    [ "$(getfacl -p "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" 2>/dev/null | grep "^user:$u:")" = "user:$u:rw-" ] || users_clip="$users_clip $u(socket)"
    if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && [ "$(getfacl -p "$XDG_RUNTIME_DIR/pipewire-0" 2>/dev/null | grep "^user:$u:")" != "user:$u:---" ]; then users_clip="$users_clip $u(pipewire)"; fi
  done
  if [ -z "$users_clip" ]; then ok users-clipboard "clipboard users reach the Wayland socket only (dir x, socket rw, pipewire closed)"; else bad users-clipboard "ACL of the runtime dir is off:$users_clip (usr clipboard-acl)"; fi
fi

# ── O1: update tool (sysup), hub groups ─────────────────────────────────────────
if [ -x "$DOTFILES/.local/bin/sysup" ] && bash -n "$DOTFILES/.local/bin/sysup" 2>/dev/null; then
  if sysup_out="$("$DOTFILES/infrastructure/tests/sysup/run.sh" 2>&1)"; then ok sysup-tests "offline tests: $(printf '%s' "$sysup_out" | tail -1)"; else bad sysup-tests "$(printf '%s' "$sysup_out" | grep -m1 '^FAIL') (infrastructure/tests/sysup/run.sh)"; fi
else
  bad sysup "~/dotfiles/.local/bin/sysup missing or has a syntax error"
fi
if systemctl --user is-enabled sysup-check.timer >/dev/null 2>&1; then ok sysup-timer "user timer sysup-check.timer is enabled (background check)"; else bad sysup-timer "sysup-check.timer not enabled (stow ., then systemctl --user enable --now sysup-check.timer)"; fi
if [ -r /var/lib/dotfiles-predownload/state ] && systemctl is-enabled dotfiles-predownload.timer >/dev/null 2>&1; then
  info sysup-download "background download active, last run $(date -d @"$(sed -n 1p /var/lib/dotfiles-predownload/state)" '+%F %H:%M')"
else
  info sysup-download "background download not installed yet (sudo ./apply-system.sh --only services)"
fi
if [ -x "$DOTFILES/.config/hypr/scripts/safe-close.sh" ] && [ -f "$DOTFILES/.config/hypr/scripts/term-procs.py" ]; then
  if sc_out="$("$DOTFILES/infrastructure/tests/safe-close/run.sh" 2>&1)"; then ok safe-close-tests "SUPER+W terminal warning: $(printf '%s' "$sc_out" | tail -1)"; else bad safe-close-tests "$(printf '%s' "$sc_out" | grep -m1 '^FAIL') (infrastructure/tests/safe-close/run.sh)"; fi
else
  bad safe-close "safe-close.sh / term-procs.py missing"
fi
if [ -x "$DOTFILES/infrastructure/tests/tmux-destroy/run.sh" ] && command -v tmux >/dev/null 2>&1; then
  if td_out="$("$DOTFILES/infrastructure/tests/tmux-destroy/run.sh" 2>&1)"; then ok tmux-destroy "session-created hook sets destroy-unattached on term-* only (private tmux server), detached-terminal cleanup: $(printf '%s' "$td_out" | tail -1)"; else bad tmux-destroy "$(printf '%s' "$td_out" | grep -m1 '^FAIL') (infrastructure/tests/tmux-destroy/run.sh)"; fi
else
  bad tmux-destroy "infrastructure/tests/tmux-destroy/run.sh or tmux missing"
fi
if o1_out="$("$DOTFILES/infrastructure/tests/o1/run.sh" 2>&1)"; then ok o1-tests "desktop helpers (displays, zoom, brightness, restart, lock, media, transcode): $(printf '%s' "$o1_out" | tail -1)"; else bad o1-tests "$(printf '%s' "$o1_out" | grep -m1 '^FAIL') (infrastructure/tests/o1/run.sh)"; fi
if edit_out="$("$DOTFILES/infrastructure/tests/edit/run.sh" 2>&1)"; then ok edit-tests "edit anywhere (SUPER+CTRL+E): $(printf '%s' "$edit_out" | tail -1)"; else bad edit-tests "$(printf '%s' "$edit_out" | grep -m1 '^FAIL') (infrastructure/tests/edit/run.sh)"; fi
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null 2>&1; then
  o1_rate="$(hyprctl getoption input:repeat_rate -j 2>/dev/null | jq -r '.int // empty')"
  o1_delay="$(hyprctl getoption input:repeat_delay -j 2>/dev/null | jq -r '.int // empty')"
  o1_click="$(hyprctl getoption input:touchpad:clickfinger_behavior -j 2>/dev/null | jq -r '.bool // empty')"
  if [ "$o1_rate" = 40 ] && [ "$o1_delay" = 250 ] && [ "$o1_click" = true ]; then ok input-feel "key repeat 40/s after 250 ms, two-finger right click"; else bad input-feel "repeat $o1_rate/$o1_delay clickfinger $o1_click (expected 40/250/true; hyprctl reload)"; fi
  o1_dk="$(hyprctl getoption misc:key_press_enables_dpms -j 2>/dev/null | jq -r '.int // .bool // empty')"
  o1_dm="$(hyprctl getoption misc:mouse_move_enables_dpms -j 2>/dev/null | jq -r '.int // .bool // empty')"
  case "$o1_dk:$o1_dm" in
    1:1 | true:true) ok dpms-wake "key press and mouse move wake a panel that hypridle switched off" ;;
    *) bad dpms-wake "misc:key_press_enables_dpms=$o1_dk mouse_move_enables_dpms=$o1_dm (both must be true; hyprctl reload)" ;;
  esac
  o1_binds="$(hyprctl binds -j 2>/dev/null | jq -r '[.[] | select(.description | test("Laptop panel on or off|Mirror the laptop panel|Zoom the screen in|Switch to the next audio output|Brightness up 1 percent|Volume up 1 percent"))] | length')"
  if [ "${o1_binds:-0}" -ge 6 ]; then ok o1-binds "display, zoom and fine-step binds are live"; else bad o1-binds "only ${o1_binds:-0} of 6 O1 binds are live (hyprctl reload)"; fi
fi
[ -x "$HOME/.local/bin/lock-screen" ] && grep -q 'lock_cmd = lock-screen' "$HOME/.config/hypr/hypridle.conf" 2>/dev/null && ok lock-layout "lock-screen resets the layout to us (bind, power menu, hub, hypridle lock_cmd)" || bad lock-layout "lock-screen missing or hypridle lock_cmd does not use it"
if grep -q 'dim.sh dim' "$HOME/.config/hypr/hypridle.conf" 2>/dev/null && grep -q 'dim.sh restore' "$HOME/.config/hypr/hypridle.conf" 2>/dev/null && grep -q 'input.keyboard.key' "$DOTFILES/.config/hypr/hyprland.lua"; then
  ok idle-dim "dim goes through dim.sh (saves only when not dimmed, restores from state, key-press restore in hyprland.lua)"
else
  bad idle-dim "hypridle.conf must call dim.sh dim / restore and hyprland.lua restore on input.keyboard.key"
fi
if [ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/idle-off" ]; then info hypridle-alive "idle is switched off on purpose (SUPER+CTRL+I)"; elif pgrep -x hypridle >/dev/null 2>&1; then ok hypridle-alive "hypridle runs"; else bad hypridle-alive "hypridle is not running (the hypridle-watch timer starts it within a minute, or SUPER+CTRL+I)"; fi
if systemctl --user is-enabled hypridle-watch.timer >/dev/null 2>&1; then ok hypridle-watch "user timer hypridle-watch.timer restarts hypridle when it died"; else bad hypridle-watch "hypridle-watch.timer not enabled (stow ., systemctl --user enable --now hypridle-watch.timer)"; fi
if systemctl --user is-active crash-watch.service >/dev/null 2>&1; then ok crash-watch "crash-watch.service follows the coredump journal (toast, details, ask Claude, mute)"; else bad crash-watch "crash-watch.service is not running (stow ., systemctl --user enable --now crash-watch.service)"; fi
if command -v voxtype >/dev/null 2>&1; then
  dict_model="$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/dictation/model" 2>/dev/null)"; dict_model="${dict_model:-small}"
  if [ -s "$HOME/.local/share/voxtype/models/ggml-$dict_model.bin" ]; then info dictation "voxtype installed, model $dict_model present, language $(cat "${XDG_STATE_HOME:-$HOME/.local/state}/dictation/lang" 2>/dev/null || echo ru)"; else info dictation "voxtype installed, model $dict_model missing (dictation.sh model)"; fi
  if systemctl --user is-active voxtype.service >/dev/null 2>&1; then ok dictation-daemon "voxtype.service runs"; else info dictation-daemon "voxtype.service is not running (it starts on first use or at login)"; fi
else
  info dictation "voxtype is not installed: SUPER+ALT+D / F9 show how to install it (sudo ./apply-system.sh --only install)"
fi
if [ "$(systemctl --user is-enabled voxtype.service 2>/dev/null)" = enabled ] && [ -r "$HOME/.config/voxtype/config.toml" ]; then ok dictation-unit "voxtype.service enabled, config tracked"; else bad dictation-unit "voxtype.service not enabled or ~/.config/voxtype/config.toml missing (stow ., systemctl --user enable voxtype.service)"; fi
# D1b: the daemon runs the variant dictation.sh picks (Vulkan when a real GPU works, else the best CPU build), started directly:
# a leftover runtime drop-in or ~/.local/share/voxtype/bin link from the manual Vulkan setup must be gone
if command -v voxtype >/dev/null 2>&1; then
  dict_stale=""
  [ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/user/voxtype.service.d/vulkan.conf" ] && dict_stale="$dict_stale runtime drop-in vulkan.conf"
  [ -e "$HOME/.local/share/voxtype/bin/voxtype" ] && dict_stale="$dict_stale ~/.local/share/voxtype/bin/voxtype"
  dict_want="$("$DOTFILES/.config/hypr/scripts/dictation.sh" backend --path 2>/dev/null)"
  dict_label="$("$DOTFILES/.config/hypr/scripts/dictation.sh" backend 2>/dev/null | sed -n 's/^backend: //p')"
  dict_pid="$(systemctl --user show voxtype.service -p MainPID --value 2>/dev/null)"
  if [ -n "$dict_stale" ]; then bad dictation-backend "leftovers of the manual Vulkan setup:$dict_stale (remove them; dictation.sh run picks the variant)"
  elif [ -z "$dict_want" ] || [ ! -x "$dict_want" ]; then bad dictation-backend "dictation.sh backend finds no voxtype binary (package voxtype-bin, /usr/lib/voxtype)"
  elif [ -n "$dict_pid" ] && [ "$dict_pid" != 0 ]; then
    if [ "$(readlink "/proc/$dict_pid/exe" 2>/dev/null)" = "$dict_want" ]; then ok dictation-backend "voxtype.service runs $(basename "$dict_want"): $dict_label"; else bad dictation-backend "voxtype.service runs $(readlink "/proc/$dict_pid/exe" 2>/dev/null) but dictation.sh picks $dict_want (systemctl --user restart voxtype)"; fi
  else info dictation-backend "voxtype.service is not running; it would start $(basename "$dict_want"): $dict_label"; fi
fi
hub_groups="$("$DOTFILES/.config/hub/hub" groups 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
hub_missing=""
for g in Setup Update Learn Fix; do case " $hub_groups " in *" $g "*) ;; *) hub_missing="$hub_missing $g" ;; esac; done
if [ -z "$hub_missing" ]; then ok hub-groups "groups Setup/Update/Learn/Fix exist (hub groups)"; else bad hub-groups "hub groups lacks:$hub_missing"; fi
if "$DOTFILES/.config/hub/hub" --json 2>/dev/null | jq -e 'length > 50 and all(.[]; has("id") and has("group") and has("available"))' >/dev/null 2>&1; then ok hub-json "hub --json lists the rows for agents"; else bad hub-json "hub --json is not valid JSON of rows"; fi

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
# a new command in .local/bin (tracked or not yet committed) must be linked into ~/.local/bin: stow only runs by hand, and a
# command that was never stowed (M1: mcp-telegram-setup) works from the repo path only
unlinked=""
n_cmds=0
while IFS= read -r -d '' rel; do
  case "$rel" in .local/bin/*/*) continue ;; .local/bin/*) ;; *) continue ;; esac
  [ -x "$DOTFILES/$rel" ] && [ -f "$DOTFILES/$rel" ] || continue
  n_cmds=$((n_cmds + 1))
  [ "$(readlink -f "$HOME/$rel" 2>/dev/null)" = "$(readlink -f "$DOTFILES/$rel")" ] || unlinked="$unlinked ${rel#.local/bin/}"
done < <(git -C "$DOTFILES" ls-files -z --cached --others --exclude-standard -- .local/bin)
if [ -z "$unlinked" ]; then
  ok stow-bin "all $n_cmds executables of .local/bin are linked into ~/.local/bin"
else
  bad stow-bin "not linked into ~/.local/bin:$unlinked (cd ~/dotfiles && stow .)"
fi
# nothing left for stow to do: a dry run lists every file it would still link (new files, dangling links)
if command -v stow >/dev/null 2>&1; then
  stow_out="$(cd "$DOTFILES" && stow -n -v . 2>&1 | grep -v '^WARNING: in simulation mode')"
  if [ -z "$stow_out" ]; then
    ok stow-clean "stow -n -v . has nothing to do"
  else
    bad stow-clean "stow would still change $(printf '%s\n' "$stow_out" | wc -l) path(s), first: $(printf '%s\n' "$stow_out" | head -1) (cd ~/dotfiles && stow .)"
  fi
else
  info stow-clean "stow is not installed"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
