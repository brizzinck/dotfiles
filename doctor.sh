#!/usr/bin/env bash
# dotfiles doctor: asserts that the approved workstation state stays in place. Read-only, no sudo.
#   ./doctor.sh              print PASS/FAIL lines and a summary (exit 1 when anything failed)
#   ./doctor.sh --fails      print only the failures
#   ./doctor.sh --live       also run the checks that touch the real hardware: audio-mic and audio-ee-signal each record 1.5 s from
#                            the microphone (statistics only, nothing is kept), which lights the privacy indicator; a Bluetooth
#                            default source is never probed (no HFP switch). Without --live both are INFO. DOCTOR_LIVE=1 does the same
# Repo-only (listed in .stow-local-ignore). Declined items (restic, keyring, ...) are intentionally not checked.
set -u

# Immune to concurrent edits: bash reads a script incrementally, so a commit that rewrites this file during a run breaks it
# mid-way ("syntax error near unexpected token"). Run from a private copy (0700 temp dir, removed afterwards, also on Ctrl+C,
# SIGTERM or SIGHUP: the signal is forwarded to the copy, the copy removed, the signal re-raised; as root TMPDIR is ignored,
# always /tmp); DOCTOR_SELF is the original path, used for the repo lookups. Falls through to running in place when the copy
# cannot be made.
if [ -z "${DOCTOR_SELF:-}" ]; then
  DOCTOR_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
  _dbase="${TMPDIR:-/tmp}"
  [ "$(id -u)" = 0 ] && _dbase=/tmp
  if _dtmp="$(mktemp -d "$_dbase/doctor.XXXXXX" 2>/dev/null)" && install -m 0700 "$DOCTOR_SELF" "$_dtmp/doctor.sh"; then
    export DOCTOR_SELF
    _drc=0 _dpid="" _dgot=""
    # The copy runs as a CHILD: a signal sent to this wrapper alone (kill, a closing terminal) is forwarded to it at once (a
    # foreground child would hold the trap back until it finished) and the copy is removed afterwards, then the signal is
    # re-raised so the caller sees the real cause of death. Ctrl+C reaches both through the process group.
    _dsig() { _dgot=$1; if [ -n "$_dpid" ]; then kill "-$1" "$_dpid" 2>/dev/null || true; fi; }
    trap '_dsig INT' INT
    trap '_dsig TERM' TERM
    trap '_dsig HUP' HUP
    env --default-signal=INT,QUIT bash "$_dtmp/doctor.sh" "$@" <&0 &   # an async child would ignore SIGINT otherwise
    _dpid=$!
    [ -z "$_dgot" ] || kill "-$_dgot" "$_dpid" 2>/dev/null || true   # a signal that arrived before the pid was known (between the fork and this line)
    while :; do
      _drc=0
      wait "$_dpid" || _drc=$?
      kill -0 "$_dpid" 2>/dev/null || break   # wait also returns when a trapped signal arrived while the child still runs
    done
    rm -rf "$_dtmp"
    if [ -n "$_dgot" ]; then trap - "$_dgot"; kill "-$_dgot" $$; fi
    exit "$_drc"
  fi
  [ -n "${_dtmp:-}" ] && rm -rf "$_dtmp"
fi

DOTFILES="$(cd "$(dirname "$DOCTOR_SELF")" && pwd)"
ONLY_FAILS=0
LIVE="${DOCTOR_LIVE:-0}"
for _darg in "$@"; do
  case "$_darg" in
    --fails) ONLY_FAILS=1 ;;
    --live) LIVE=1 ;;
  esac
done

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
# MENU-UX: exact search / keywords / global first (fixture + live database, no tmux in the quick variant)
if [ -x "$DOTFILES/infrastructure/tests/keymap/run.sh" ]; then
  if km_out="$("$DOTFILES/infrastructure/tests/keymap/run.sh" --quick 2>&1)"; then ok keymap-tests "shortcut search: $(printf '%s' "$km_out" | tail -1)"; else bad keymap-tests "$(printf '%s' "$km_out" | grep -m1 '^FAIL') (infrastructure/tests/keymap/run.sh --quick)"; fi
else
  bad keymap-tests "infrastructure/tests/keymap/run.sh missing"
fi
# U8: SUPER+CTRL+U types the Linux password of the user the focused window asks for (vault.sh user-pass + vault-who.py)
if [ -x "$DOTFILES/.config/hypr/scripts/vault.sh" ] && [ -r "$DOTFILES/.config/hypr/scripts/vault-who.py" ]; then
  if python3 -I -B "$DOTFILES/.config/hypr/scripts/vault-who.py" --pid "$$" --class doctor | jq -e '.kind == "other" and (.user | length > 0)' >/dev/null 2>&1; then
    ok vault-userpass "vault-who.py answers (offline probe on this shell)"
  else
    bad vault-userpass "vault-who.py does not answer (python3 -I -B .config/hypr/scripts/vault-who.py --pid \$\$ --class doctor)"
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
# BW-ORG: the vault reorganisation (vault-audit) and the vault-share broker for td / yc. Names never leave these checks: counts only.
vo_audit="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vault/org/audit.json"
vo_plan="${XDG_STATE_HOME:-$HOME/.local/state}/vault/org-plan.tsv"
vo_journal="${XDG_STATE_HOME:-$HOME/.local/state}/vault/org-journal.tsv"
if [ -r "$DOTFILES/.config/hypr/scripts/vault-org.py" ]; then
  vo_msg=""
  if [ -r "$vo_audit" ]; then
    vo_msg="$(jq -r '"last audit \(.created): \(.items|length) items, \(.groups|length) duplicate groups, \(.findings.no_folder|length) without a folder, \(.findings.empty_folder|length) empty folders, \(.findings.tool_folder|length) tool-folder problems, \(.findings.near_dup_folder|length + (.findings.near_dup_name|length)) near-duplicates"' "$vo_audit" 2>/dev/null)"
  fi
  [ -n "$vo_msg" ] || vo_msg="no audit in memory (it is dropped on lock and login; not run yet: vault-audit)"
  if [ -r "$vo_plan" ]; then
    vo_msg="$vo_msg; plan: $(awk -F'\t' '!/^#/ && NF >= 5 && $4 != "keep" {n++} END {print n + 0}' "$vo_plan") changes pending"
  fi
  if [ -r "$vo_journal" ]; then
    vo_msg="$vo_msg; journal: $(awk -F'\t' '!/^#/ && $4 ~ /^ok/ {o++} !/^#/ && $4 !~ /^ok/ {f++} END {print o + 0 " ok, " f + 0 " skipped or failed"}' "$vo_journal")"
  fi
  info vault-org "$vo_msg"
  if vo_out="$("$DOTFILES/infrastructure/tests/vault-org/run.sh" --quick 2>&1)"; then
    ok vault-org-test "offline test with the fake vault: $(printf '%s' "$vo_out" | tail -1)"
  else
    bad vault-org-test "offline test failed (infrastructure/tests/vault-org/run.sh --quick): $(printf '%s' "$vo_out" | grep -m1 '^FAIL')"
  fi
else
  bad vault-org ".config/hypr/scripts/vault-org.py missing"
fi
vs_py="$DOTFILES/.config/hypr/scripts/vault-share.py"
vs_file=/etc/vault-share/scopes.tsv
if [ -r "$vs_py" ]; then
  if [ -e "$vs_file" ]; then
    if vs_guard="$(python3 -I -B "$vs_py" check-rbw 2>&1)"; then
      ok vault-share-rbw "supported pinentry-themed wrapper; broker requests cannot prompt or start an rbw agent"
    else
      bad vault-share-rbw "${vs_guard:-cannot validate rbw pinentry}; owner fix: rbw config set pinentry \"$DOTFILES/.local/bin/pinentry-themed\""
    fi

    vs_bad="" vs_grp="$(id -gn)" vs_me="$(id -un)"
    [ "$(stat -c '%U:%G %a' "$vs_file" 2>/dev/null)" = "root:$vs_grp 640" ] || vs_bad="$vs_file is '$(stat -c '%U:%G %a' "$vs_file" 2>/dev/null)', want 'root:$vs_grp 640'"
    python3 -I -B "$vs_py" check-scopes "$vs_file" --owner "$vs_me" >/dev/null 2>&1 || vs_bad="$vs_bad; $vs_file fails check-scopes"
    [ "$(stat -c '%U:%G %a' /etc/vault-share 2>/dev/null)" = "root:root 755" ] || vs_bad="$vs_bad; /etc/vault-share is not root:root 755"
    if [ "$(stat -c '%U:%G %a' /run/vault-share 2>/dev/null)" != "$vs_me:$vs_grp 755" ]; then vs_bad="$vs_bad; /run/vault-share is '$(stat -c '%U:%G %a' /run/vault-share 2>/dev/null)', want '$vs_me:$vs_grp 755'"; fi
    if command -v getfacl >/dev/null 2>&1 && getfacl -cp /run/vault-share 2>/dev/null | grep -qE '^(user|group):[^:]+:'; then vs_bad="$vs_bad; /run/vault-share has an ACL"; fi
    if [ -S /run/vault-share/sock ]; then
      [ "$(stat -c '%a %U' /run/vault-share/sock 2>/dev/null)" = "666 $vs_me" ] || vs_bad="$vs_bad; the socket is not 0666 owned by $vs_me"
    fi
    systemctl --user is-active vault-share.socket >/dev/null 2>&1 || vs_bad="$vs_bad; vault-share.socket is not active (systemctl --user enable --now vault-share.socket)"
    if python3 -I -B "$vs_py" selftest >/dev/null 2>&1; then :; else vs_bad="$vs_bad; selftest: the broker does not answer 'refused' with the real owner uid (a user namespace? journalctl --user -u vault-share)"; fi
    for vs_u in $(awk -F'\t' '!/^[[:space:]]*#/ && NF {print $1}' "$DOTFILES/infrastructure/users/managed.tsv" 2>/dev/null); do
      id -u "$vs_u" >/dev/null 2>&1 || continue
      vs_reach="$(python3 -I -B "$DOTFILES/infrastructure/users/acl-reach.py" "$(id -u "$vs_u")" "/run/user/$(id -u)" 2>/dev/null | grep 'rbw/socket' | head -1)"
      [ -n "$vs_reach" ] && vs_bad="$vs_bad; $vs_u can reach the rbw agent socket ($vs_reach)"
    done
    if [ -n "$vs_bad" ]; then bad vault-share "${vs_bad#; }"; else ok vault-share "scopes root:$vs_grp 640 and valid, /run/vault-share $vs_me:$vs_grp 755 without an ACL, socket 0666, selftest refused the owner with his real uid, no managed user reaches the rbw agent"; fi
    if command -v rbw >/dev/null 2>&1 && rbw unlocked >/dev/null 2>&1; then
      info vault-share-scope "$(python3 -I -B "$vs_py" report 2>/dev/null | paste -sd';' | sed 's/;/; /g') (counts only, from the unlocked rbw)"
    else
      info vault-share-scope "not counted (rbw locked); vault-share report shows the items in scope per user"
    fi
  else
    info vault-share "not applied yet: sudo ./apply-system.sh --only users renders /etc/vault-share/scopes.tsv and creates /run/vault-share"
  fi
  if vs_out="$("$DOTFILES/infrastructure/tests/vault-share/run.sh" --quick 2>&1)"; then
    ok vault-share-test "offline test (scope grammar, broker with a fake rbw): $(printf '%s' "$vs_out" | tail -1)"
  else
    bad vault-share-test "offline test failed (infrastructure/tests/vault-share/run.sh --quick): $(printf '%s' "$vs_out" | grep -m1 '^FAIL')"
  fi
  # td / yc from before the broker: their own rbw copy is an encrypted copy of the owner's vault (paths only; the fix is the owner's choice)
  vs_old=""
  for vs_u in $(awk -F'\t' '!/^[[:space:]]*#/ && NF && $3 !~ /service/ {print $1}' "$DOTFILES/infrastructure/users/managed.tsv" 2>/dev/null); do
    vs_home="$(getent passwd "$vs_u" | cut -d: -f6)"
    [ -n "$vs_home" ] || continue
    for vs_p in "$vs_home/.config/rbw/config.json" "$vs_home/.cache/rbw" "$vs_home/.config/Bitwarden CLI"; do
      [ -e "$vs_p" ] && vs_old="$vs_old $vs_p"
    done
    pgrep -u "$vs_u" rbw-agent >/dev/null 2>&1 && vs_old="$vs_old (rbw-agent of $vs_u runs)"
  done
  if [ -n "$vs_old" ]; then
    info vault-share-stale "old vault data of a managed user (an encrypted copy of your vault):${vs_old}; remove with: usr exec td -- rbw purge; usr exec td -- rm -rf ~/.config/rbw ~/.cache/rbw ~/.config/'Bitwarden CLI'"
  else
    info vault-share-stale "no rbw or bw data of a managed user left"
  fi
else
  bad vault-share ".config/hypr/scripts/vault-share.py missing"
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
    bw_reach="$(python3 -I -B "$DOTFILES/infrastructure/users/acl-reach.py" "$(id -u "$bw_u")" "$(dirname "$bw_run")" 2>/dev/null | grep 'vault/bw.sock' | head -1)"
    [ -n "$bw_reach" ] && bw_bad="$bw_bad; $bw_u can reach it ($bw_reach)"
  done
  if [ -n "$bw_bad" ]; then bad vault-bw-serve "${bw_bad#; }"; else ok vault-bw-serve "bw serve on $bw_run/bw.sock: socket 600, dir 700, no TCP listener, no other user can reach it"; fi
elif [ -n "$bw_bad" ]; then
  bad vault-bw-serve "${bw_bad#; }"
else
  info vault-bw-serve "not running (starts on the first Trash / edit / new action after the bw unlock; no TCP listener)"
fi
# FIX3 F5: the bw processes that hold the session key run non-dumpable (a crash must not put the environment into the journal):
# the LD_PRELOAD library is built per boot in $XDG_RUNTIME_DIR/vault and probed once; INFO when it cannot be (no cc, failed probe)
if [ -r "$DOTFILES/.config/hypr/scripts/vault-bw.py" ]; then
  # nodump-status is read-only (it never compiles; the first bw call that holds a session key builds the library); the running bw
  # processes are looked at too: a non-dumpable process has /proc/PID/environ owned by root
  nd_out="$(python3 -I -B "$DOTFILES/.config/hypr/scripts/vault-bw.py" nodump-status 2>&1)"
  nd_open=0 nd_all=0
  for nd_p in $(pgrep -u "$(id -u)" -x bw 2>/dev/null); do
    nd_all=$((nd_all + 1))
    [ "$(stat -c %U "/proc/$nd_p/environ" 2>/dev/null)" = root ] || nd_open=$((nd_open + 1))
  done
  if [ "$nd_out" = yes ] && [ "$nd_open" = 0 ]; then
    ok vault-nodump "bw processes that hold the session key are non-dumpable (library there and probed; $nd_all running bw process(es) all protected)"
  elif [ "$nd_out" = yes ]; then
    info vault-nodump "library present, but $nd_open of $nd_all running bw process(es) are still dumpable (started before it was built; vault-bw.py serve-stop, the next bw action restarts them)"
  else
    info vault-nodump "bw processes non-dumpable: $nd_out; a crashing bw can log its environment (COREDUMP_ENVIRON)"
  fi
fi
# FIX3 F6: dead tmux socket files (kill-server leaves them; every test suite and tool now removes its own)
tm_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
if [ -d "$tm_dir" ] && command -v ss >/dev/null 2>&1; then
  tm_live="$(ss -xlH 2>/dev/null | awk '{print $5}')"
  tm_dead=0
  while IFS= read -r tm_f; do grep -qxF -- "$tm_f" <<<"$tm_live" || tm_dead=$((tm_dead + 1)); done < <(find "$tm_dir" -maxdepth 1 -type s 2>/dev/null)
  if [ "$tm_dead" -le 10 ]; then ok tmux-sockets "$tm_dead dead tmux socket file(s) in $tm_dir"; else info tmux-sockets "$tm_dead dead tmux socket files in $tm_dir (leftovers of old test runs, harmless): cd $tm_dir && for f in *; do tmux -L \"\$f\" ls >/dev/null 2>&1 || rm -f \"\$f\"; done"; fi
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
    && ! jq -r '.mcpServers.telegram.options.toolFilter.list[]' "$HOME/.config/mcp/gateway.json" 2>/dev/null | grep -vxE 'download_media|export_history' | grep -qE '^(send|reply|edit|delete|forward|mark|save|upload|download|press|join|leave|invite|ban|unban|pin|unpin|set_|create|update|promote|demote|add_|remove|block|unblock|mute|unmute|archive|unarchive|import|export|clear|toggle|vote|subscribe|enable|disable)'; then
    ok mcp-toolfilter "telegram toolFilter is an allow list without send/edit/delete/mark tools (local file tools: download_media, export_history)"
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
    for tg_f in run serve.py creds-install login.py call_metadata.py chat_export.py telegram_files.py; do cmp -s "$tg_dir/$tg_f" "/usr/local/lib/telegram-mcp/$tg_f" || tg_drift="$tg_drift $tg_f"; done
    for tg_f in telegram-mcp.service telegram-whisper.service telegram-whisper-proxy.service telegram-whisper-proxy.socket; do cmp -s "$tg_dir/$tg_f" "/etc/systemd/system/$tg_f" || tg_drift="$tg_drift $tg_f"; done
    if [ -z "$tg_drift" ]; then ok mcp-tg-files "telegram-mcp scripts and units match the repo"; else bad mcp-tg-files "installed files differ from the repo:$tg_drift (sudo ./apply-system.sh --only mcp)"; fi
  else
    info mcp-tg-files "Telegram service not installed yet: sudo ./apply-system.sh --only users,mcp"
  fi
  # a failed Bitwarden write of a fresh Telegram session leaves a plaintext full-account session in a recovery file that every process
  # of yours (agents too) can read: FAIL until it is resumed or deleted
  if tg_rec="$("$DOTFILES/.local/bin/mcp-telegram-setup" recovery-status 2>/dev/null)"; then
    ok mcp-tg-recovery "no plaintext Telegram session waiting in a recovery file"
  elif [ -n "$tg_rec" ]; then
    bad mcp-tg-recovery "a Telegram session may sit in plaintext in $(printf '%s' "$tg_rec" | paste -sd, - | sed 's/,/, /g') (readable by every process of yours): mcp-telegram-setup --resume, or delete the file(s)"
  else
    info mcp-tg-recovery "mcp-telegram-setup recovery-status gave no answer"
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
  jq -e '.mcpServers["telegram-send"].options.toolFilter | .mode == "allow" and ((.list | sort) == ["send_file", "send_message", "status"])' "$HOME/.config/mcp/gateway.json" >/dev/null 2>&1 \
    || snd_bad="$snd_bad; gateway.json: telegram-send toolFilter must allow exactly send_file + send_message + status"
  grep -qs 'telegram-send' "${CODEX_HOME:-$HOME/.codex}/config.toml" && snd_bad="$snd_bad; telegram-send is registered for Codex (Codex has no permission rules: mcp-add removes it)"
  for snd_f in /etc/credstore.encrypted/telegram-mcp.send_token /etc/credstore.encrypted/tgconfirm.send_token; do
    [ -r "$snd_f" ] && snd_bad="$snd_bad; $snd_f is readable by $USER"
  done
  find "$mcp_state" -maxdepth 1 -iname '*send*token*' 2>/dev/null | grep -q . && snd_bad="$snd_bad; a send token file exists in $mcp_state"
  if [ -r /etc/systemd/system/tgconfirm.service ]; then
    snd_drift=""
    for snd_f in broker.py popup.py telegram_files.py; do cmp -s "$DOTFILES/infrastructure/mcp/confirm/$snd_f" "/usr/local/lib/tgconfirm/$snd_f" || snd_drift="$snd_drift $snd_f"; done
    cmp -s "$DOTFILES/infrastructure/mcp/confirm/tgconfirm.service" /etc/systemd/system/tgconfirm.service || snd_drift="$snd_drift tgconfirm.service"
    cmp -s "$tg_dir/send.conf" /usr/local/lib/telegram-mcp/send.conf || snd_drift="$snd_drift send.conf"
    if [ -z "$snd_drift" ]; then ok mcp-send-files "tgconfirm broker, popup, unit and send.conf match the repo"; else bad mcp-send-files "installed files differ from the repo:$snd_drift (sudo ./apply-system.sh --only mcp)"; fi
    if getent passwd tgconfirm >/dev/null; then
      getfacl -p "$HOME" 2>/dev/null | grep -q 'tgconfirm' && snd_bad="$snd_bad; tgconfirm has an ACL entry on $HOME"
      # everything tgconfirm can reach in the runtime dir, by the kernel's rules (named ACL entry, else the OTHER bits): only the Wayland socket
      snd_acl="$(python3 -I -B "$DOTFILES/infrastructure/users/acl-reach.py" "$(id -u tgconfirm)" "/run/user/$(id -u)" --allow "$(basename "${WAYLAND_DISPLAY:-wayland-1}")" 2>&1 | head -4 | paste -sd';')"
      [ -n "$snd_acl" ] && snd_bad="$snd_bad; tgconfirm can reach in /run/user/$(id -u) (named ACL or other bits): $snd_acl (only the Wayland socket is allowed; run: usr clipboard-acl)"
      sudo -k -n -u tgconfirm true >/dev/null 2>&1 && snd_bad="$snd_bad; the owner can reach tgconfirm without a password"
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
      if snd_wl="$(python3 -I -B "$DOTFILES/infrastructure/mcp/confirm/broker.py" --check-wayland 2>&1)"; then ok mcp-send-wayland "the broker's socket check accepts the live session ($snd_wl)"
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
    elif [ -z "$snd_bad" ]; then ok mcp-send-route "/x-send refuses the MCP token, telegram-send is Claude-only with send_file + send_message + status, no send credential readable, tgconfirm has only the Wayland socket"
    else bad mcp-send-route "${snd_bad#; }"; fi
  else
    info mcp-send-files "tgconfirm is not installed yet: sudo ./apply-system.sh --only users,mcp, then mcp-telegram-setup send-chats"
    if [ -z "$snd_bad" ]; then info mcp-send-route "sending is not set up yet; the repo-side rules hold (telegram-send allow list, not in Codex, no send credential readable)"
    else bad mcp-send-route "${snd_bad#; }"; fi
  fi
  if "$HOME/.local/bin/mcp-guard" --check >/dev/null 2>&1; then ok mcp-guard "Claude Code denies wtype, wlrctl, hyprd, hyprctl eval/dispatch and grim to the agents' Bash"
  else info mcp-guard "deny rules for key injection and capture are not in Claude Code's settings yet: mcp-guard (mcp-add runs it)"; fi
  if [ -s /srv/models/ggml-small.bin ]; then ok mcp-whisper "Whisper model shared in /srv/models ($(stat -c %s /srv/models/ggml-small.bin) bytes)"; else info mcp-whisper "no /srv/models/ggml-small.bin yet (sudo ./apply-system.sh --only mcp)"; fi
  if [ -x /usr/bin/chromium ]; then ok mcp-chromium "Chromium for the clean chrome-devtools server is installed"; else info mcp-chromium "chromium not installed: chrome-devtools answers with a stub (sudo ./apply-system.sh --only mcp)"; fi
else
  bad mcp-gateway ".local/bin/mcp-gateway missing (cd ~/dotfiles && stow .)"
fi
# ── V1b: the shared modal fzf (vim keys in every menu) ──────────────────────────────────────────────────────────
if [ -x "$HOME/.local/bin/fzf-menu" ] && [ -r "$HOME/.config/fzf/vimfzf.sh" ]; then
  if out="$("$HOME/.local/bin/fzf-menu" --self-test 2>&1)"; then ok fzf-menu "modal self-test passed ($(printf '%s\n' "$out" | grep -c '^ok') cases)"; else bad fzf-menu "$(printf '%s\n' "$out" | grep -m1 'FAIL\|self-test')"; fi
  if [ -x "$DOTFILES/infrastructure/tests/fzf-menu/run.sh" ]; then
    if fm_out="$("$DOTFILES/infrastructure/tests/fzf-menu/run.sh" --quick 2>&1)"; then ok fzf-menu-tests "one-shot server terminals: $(printf '%s' "$fm_out" | tail -1)"; else bad fzf-menu-tests "$(printf '%s' "$fm_out" | grep -m1 '^FAIL') (infrastructure/tests/fzf-menu/run.sh --quick)"; fi
  else
    bad fzf-menu-tests "infrastructure/tests/fzf-menu/run.sh missing"
  fi
  if [ -p "${XDG_RUNTIME_DIR:-/tmp}/fzf-menu/server.fifo" ] && kill -0 "$(cat "${XDG_RUNTIME_DIR:-/tmp}/fzf-menu/server.pid" 2>/dev/null)" 2>/dev/null; then
    slot="$(cat "${XDG_RUNTIME_DIR:-/tmp}/fzf-menu/server.slot" 2>/dev/null)"
    if [ -n "$slot" ]; then info fzf-menu-server "one-shot menu terminal running, active slot $slot (menus open in ~40 ms)"; else info fzf-menu-server "hidden menu terminal running (old single server: restart it from hub > Fix > fzf-server for the one-shot terminals)"; fi
  else
    info fzf-menu-server "not running: menus start a cold ghostty (~0.4 s); fzf-menu --server-start"
  fi
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
bar_err="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 -I -B - "$DOTFILES/.config/waybar" "$bar_state" <<'PY' 2>&1
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
  # An output that is dpms-off presents no frames, and Hyprland only finishes frame-driven work in a render pass: the closing
  # fade of a layer (a `bar.sh restart` leaves a pid -1 ghost layer) and the fade-out of its error bar (a config error from a
  # reload; the bar reserves 61 px at 1.5 scale and pushes the bars and windows down) stay as they were until the panel wakes
  # (hypridle dpms off after 20 min idle). Those monitors are skipped here instead of reported as a broken bar.
  bar_mons="$(hyprctl monitors -j 2>/dev/null | jq -c '[.[] | select(.dpmsStatus != false)]')"
  bar_off="$(hyprctl monitors -j 2>/dev/null | jq -r '[.[] | select(.dpmsStatus == false) | .name] | join(" ")')"
  layers_err="$(jq -rn --argjson L "$(hyprctl layers -j 2>/dev/null)" --argjson M "${bar_mons:-[]}" \
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
  res_err="$(printf '%s' "${bar_mons:-[]}" | jq -r --argjson w "$want_top" '[.[] | select(.reserved[1] != $w) | "\(.name) reserved \(.reserved[1])" + (if (.solitaryBlockedBy // [] | index("CONFIGERROR")) then " (the Hyprland error bar is up: hyprctl configerrors, fix the config and hyprctl reload)" else "" end)] | join("; ")')"
  if [ -z "$res_err" ]; then ok bar-reserved "reserved top strip is ${want_top}px on every awake monitor"; else bad bar-reserved "$res_err (expected $want_top)"; fi
  [ -n "$bar_off" ] && info bar-panel-off "$bar_off dpms off: layers and reserved area are not refreshed until it wakes (no frames), so bar-layers / bar-reserved skip it"
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
    want="$(python3 -I -B -c 'import json,sys; t=json.load(open(sys.argv[1]))["shared"]["tokens"]; print(t["green"].lower(), t["bg_oled"].lower())' "$DOTFILES/themes/palette/everforest.json" 2>/dev/null)"
    want_fill="${want% *}"; want_line="${want#* }"
    got="$(python3 -I -B -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["fill"].lower(), p["outline"].lower(), p["accent"].lower())' "$DOTFILES/themes/generated/black/pointer.json" 2>/dev/null)"
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
  audio_err="$("$DOTFILES/.local/bin/audio-ensure" --check 2>&1)" && ok audio "cards on their saved profiles, hardware sink and source present, default source is a microphone (not easyeffects_source)" \
    || bad audio "$(printf '%s' "$audio_err" | paste -sd';' | sed 's/;/; /g') (fix: ~/.local/bin/audio-ensure)"
else
  info audio "PipeWire not reachable from this shell, skipped"
fi
if grep -q 'audio-ensure --boot' "$DOTFILES/.config/hypr/hyprland.lua"; then ok audio-boot "autostart runs audio-ensure --boot (restarts wireplumber once when a card came up on profile off)"; else bad audio-boot "hyprland.lua must run audio-ensure --boot"; fi

# audio-mic: the default source must deliver a varying signal (LENOVO 83HY: UCM named the unconnected ACP PDM "Mic1" and the source was a
# constant rail; 51-hda-no-ucm.conf fixes it). 1.5 s are measured, only statistics are printed, no audio is kept.
if [ "$LIVE" != 1 ]; then
  info audio-mic "not measured (it records 1.5 s from the real microphone and lights the privacy indicator): ./doctor.sh --live, or audio-ensure --mic"
elif command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
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

# ── AUDIO2: EasyEffects (RNNoise) in front of every microphone. The default source stays the best real microphone (52-mic-priority.conf),
# EasyEffects follows it and moves the recording apps into easyeffects_source; audio-ensure --boot starts easyeffects.service and checks it.
ee_installed=0; [ -x /usr/bin/easyeffects ] && ee_installed=1
if [ "$ee_installed" = 1 ]; then
  ee_bad=()
  ee_prep="$HOME/.config/easyeffects/db/easyeffectsrc"
  ee_link="$HOME/.local/share/easyeffects/input/mic-clean.json"
  ee_src="$DOTFILES/.config/audio/easyeffects-mic.json"
  for f in .config/wireplumber/wireplumber.conf.d/52-mic-priority.conf .config/systemd/user/easyeffects.service .config/audio/easyeffects-mic.json; do
    [ "$(readlink -f "$HOME/$f" 2>/dev/null)" = "$(readlink -f "$DOTFILES/$f")" ] || ee_bad+=("$f is not stowed (cd ~/dotfiles && stow .)")
  done
  if [ -e "$ee_link" ] || [ -L "$ee_link" ]; then
    [ "$(readlink -f "$ee_link")" = "$(readlink -f "$ee_src")" ] || ee_bad+=("preset link $ee_link does not resolve to the repo preset (ee-ctl prepare)")
  elif [ -e "$ee_prep" ]; then
    ee_bad+=("preset link $ee_link is missing (ee-ctl prepare)")
  fi
  [ ! -L "$HOME/.config/easyeffects" ] || ee_bad+=("$HOME/.config/easyeffects is a symlink (the old repo-tracked setup; ee-ctl prepare needs a real directory)")
  if [ -f "$ee_prep" ] && grep -Eq '(pitch|autotune|autogain)#' "$ee_prep"; then ee_bad+=("the EasyEffects rc still lists pitch/autotune/autogain (ee-ctl restart)"); fi
  [ ! -e "$HOME/.config/autostart/com.github.wwmm.easyeffects.desktop" ] || ee_bad+=("the XDG autostart file com.github.wwmm.easyeffects.desktop is back")
  ! grep -q 'exec_cmd("easyeffects' "$DOTFILES/.config/hypr/hyprland.lua" || ee_bad+=("hyprland.lua starts easyeffects directly (the unit does it)")
  if [ "${#ee_bad[@]}" -eq 0 ]; then
    ok audio-ee-files "preset linked to the repo, 52-mic-priority.conf + easyeffects.service stowed, old pitch/autotune setup and autostart gone"
  else
    bad audio-ee-files "$(printf '%s; ' "${ee_bad[@]}" | sed 's/; $//')"
  fi
  if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
    ee_out="$("$DOTFILES/.local/bin/audio-ensure" --ee 2>&1)"; ee_rc=$?
    case "$ee_rc" in
      0) ok audio-ee-chain "microphone -> EasyEffects RNNoise -> apps, default source $(pactl get-default-source 2>/dev/null)$(printf '%s' "$ee_out" | grep '^note:' | paste -sd';' | sed 's/^/ (/; s/$/)/; s/^ ()$//')" ;;
      1) bad audio-ee-chain "$(printf '%s' "$ee_out" | grep -v '^note:' | paste -sd';' | sed 's/;/; /g') (fix: ee-ctl restart, or ~/.local/bin/audio-ensure)" ;;
      *) info audio-ee-chain "$ee_out" ;;
    esac
    # recording is opt-in: a probe lights the microphone indicator and makes a Bluetooth headset switch to HFP (music drops)
    if [ "$LIVE" = 1 ]; then
      ee_sig="$("$DOTFILES/.local/bin/audio-ensure" --mic --chain 2>&1)"; ee_src_rc=$?
      case "$ee_src_rc" in
        0) ok audio-ee-signal "$ee_sig" ;;
        1 | 4) bad audio-ee-signal "$ee_sig (fix: ee-ctl restart, ~/.local/bin/audio-ensure --ee --verbose)" ;;
        *) info audio-ee-signal "$ee_sig" ;;
      esac
    else
      info audio-ee-signal "not run (it records 1.5 s from the microphone); run ./doctor.sh --live or ~/.local/bin/audio-ensure --mic --chain"
    fi
  else
    info audio-ee-chain "PipeWire not reachable from this shell, skipped"
    info audio-ee-signal "PipeWire not reachable from this shell, skipped"
  fi
  # the dictation daemon keeps the raw microphone (offline A/B: RNNoise in front of Whisper did not help, CLAUDE.md "Audio").
  # Read only: the script must export PIPEWIRE_PROPS node.dont-move and the RUNNING daemon must carry it in its environment
  # (a daemon started before the change keeps the old one); no config is rewritten and no transcription probe runs.
  dict_sh="$DOTFILES/.config/hypr/scripts/dictation.sh"
  if ! grep -q "local props='{ node.dont-move = true }'" "$dict_sh" || ! grep -q 'export PIPEWIRE_PROPS="\$props"' "$dict_sh"; then
    bad audio-dictation-raw "dictation.sh does not export PIPEWIRE_PROPS node.dont-move (EasyEffects would feed Whisper)"
  else
    vx_pid="$(systemctl --user show -p MainPID --value voxtype.service 2>/dev/null)"
    if [ -n "$vx_pid" ] && [ "$vx_pid" != 0 ] && [ -r "/proc/$vx_pid/environ" ]; then
      if tr '\0' '\n' <"/proc/$vx_pid/environ" 2>/dev/null | grep -q '^PIPEWIRE_PROPS=.*node.dont-move'; then
        ok audio-dictation-raw "dictation.sh exports PIPEWIRE_PROPS node.dont-move and the running daemon (pid $vx_pid) carries it (Whisper hears the raw microphone)"
      else
        bad audio-dictation-raw "the running voxtype daemon (pid $vx_pid) has no PIPEWIRE_PROPS node.dont-move: systemctl --user restart voxtype (EasyEffects would feed Whisper)"
      fi
    else
      ok audio-dictation-raw "dictation.sh exports PIPEWIRE_PROPS node.dont-move (the voxtype daemon is not running, the next start carries it)"
    fi
  fi
else
  info audio-ee-files "EasyEffects is not installed, mic chain checks skipped"
fi
if ae_out="$("$DOTFILES/infrastructure/tests/audio/run.sh" --quick 2>&1)"; then ok audio-tests "mic chain (ee-ctl, audio-ensure, picker, toggles, static files): $(printf '%s' "$ae_out" | tail -1)"; else bad audio-tests "$(printf '%s' "$ae_out" | grep -m1 '^FAIL') (infrastructure/tests/audio/run.sh)"; fi

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
lit="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 -I -B - "$DOTFILES" <<'PY' 2>&1
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
  # no unintended extended ACL (default skeletons make new files 0650/0750) and the secret locations are owner-only; bounded scan
  # (top 5 levels + the secret locations, 10 s); INFO until the users section ran with the cleanup (marker file), FAIL after it
  if [ -x "$DOTFILES/infrastructure/users/home-acl.sh" ]; then
    ha_out="$("$DOTFILES/infrastructure/users/home-acl.sh" check --budget 10 2>/dev/null)"
    ha_get() { printf '%s\n' "$ha_out" | sed -n "s/^$1=//p" | head -1; }
    ha_acl="$(ha_get acl_count)"; ha_mode="$(ha_get mode_count)"; ha_part="$(ha_get partial)"; ha_mark="$(ha_get marker)"
    ha_note=""; [ "$ha_part" = 1 ] && ha_note=" (scan stopped at the time budget: partial)"
    ha_msg=""
    [ "${ha_acl:-0}" -gt 0 ] && ha_msg="$ha_acl unintended extended ACL(s) under $HOME, e.g. $(ha_get acl_examples)"
    [ "${ha_mode:-0}" -gt 0 ] && ha_msg="${ha_msg:+$ha_msg; }$ha_mode secret path(s) group/other accessible, e.g. $(ha_get mode_examples)"
    if [ -z "$ha_out" ]; then
      info home-acl "home-acl.sh check gave no answer (run: infrastructure/users/home-acl.sh check)"
    elif [ -z "$ha_msg" ]; then
      ok home-acl "no unintended extended ACL, secret locations owner-only$ha_note"
    elif [ "$ha_mark" = 1 ]; then
      bad home-acl "$ha_msg$ha_note; fix: sudo ./apply-system.sh --only users (preview: infrastructure/users/home-acl.sh report)"
    else
      info home-acl "$ha_msg$ha_note; the users section has not run the cleanup yet: sudo ./apply-system.sh --only users"
    fi
  else
    bad home-acl "infrastructure/users/home-acl.sh is missing or not executable"
  fi
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
  # Private payloads are never read by doctor: validate owner/modes/ACLs and certification metadata only.
  if [ -d /srv/private ]; then
    if "$DOTFILES/infrastructure/users/private-publish.py" validate >/dev/null 2>&1; then
      if [ -f /srv/private/.published ]; then
        ok users-private "checked private owner/modes/read-only ACLs and publication marker"
      else
        info users-private "private layer prepared, no certified revision (usr sync as publisher)"
      fi
    else
      bad users-private "unsafe private owner/path/ACL (sudo ./apply-system.sh --only users)"
    fi
  else
    info users-private "/srv/private is not set up (sudo ./apply-system.sh --only users)"
  fi
  if users_private_group=$(getent group dotfiles-private); then
    users_private_gid=$(printf '%s' "$users_private_group" | cut -d: -f3)
    users_private_actual=$(printf '%s' "$users_private_group" | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort -u)
    users_private_expected=$(private_publish_members | sort -u)
    users_private_primary=$(getent passwd | awk -F: -v gid="$users_private_gid" '$4==gid {print $1}')
    if [ "$users_private_actual" = "$users_private_expected" ] && [ -z "$users_private_primary" ]; then
      ok users-private-group "exact existing interactive profile members; no primary-group accounts"
    else
      bad users-private-group "private group roster drift (sudo ./apply-system.sh --only users)"
    fi
  else
    info users-private-group "dedicated group absent (sudo ./apply-system.sh --only users)"
  fi
  # Read only the safe scan marker, public policy/scanner metadata and private HEAD object identity.
  if [ -f /srv/private/.published ]; then
    if python3 -I -B - "$DOTFILES" <<'PY_PRIVATE_MARKER'
import hashlib, importlib.util, json, os, pathlib, re, stat, subprocess, sys
repo=pathlib.Path(sys.argv[1]); helper=repo/'infrastructure/users/private-publish.py'
spec=importlib.util.spec_from_file_location('private_doctor',helper)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
try:
    root=pathlib.Path('/srv/private');uid=m.anchor_owner(root)
    marker=root/'.published';m.checked_path(marker)
    fd=os.open(marker,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as source:
        st=os.fstat(source.fileno())
        assert stat.S_ISREG(st.st_mode) and st.st_uid==uid and st.st_nlink==1 and st.st_size<4096
        data=json.loads(source.read(4096))
    policy=hashlib.sha256(helper.read_bytes()+(helper.parent/'private-deny.txt').read_bytes()+(helper.parent/'private-links.tsv').read_bytes()).hexdigest()
    current=subprocess.run(['git','-C',str(repo/'private'),'rev-parse','HEAD^{commit}'],capture_output=True,text=True,timeout=5,check=True).stdout.strip()
    scanner=subprocess.run(['gitleaks','version'],capture_output=True,text=True,timeout=5,check=True).stdout.strip()
    assert data.get('rev')==current and data.get('policy')==policy and data.get('scanner')==scanner
    assert re.fullmatch('[0-9a-f]{64}',data.get('manifest','')) and isinstance(data.get('time'),int)
except Exception:
    sys.exit(1)
PY_PRIVATE_MARKER
    then ok users-private-scan "certified private revision/policy/scanner metadata is current; no payload scan run"
    else bad users-private-scan "scan/publication certification stale or invalid (usr sync as publisher)"; fi
  else
    info users-private-scan "no certified private scan metadata yet (usr sync as publisher)"
  fi
  secret_source_check=$("$DOTFILES/infrastructure/users/private-publish.py" migrate --dry-run 2>&1)
  secret_source_rc=$?
  if [ "$secret_source_rc" -ne 0 ]; then
    if [[ $secret_source_check == *"both secret files exist"* ]] && python3 -I -B - "$DOTFILES" <<'PY_SECRET_CONFLICT'
import importlib.util, os, pathlib, sys
path=pathlib.Path(sys.argv[1])/'infrastructure/users/private-publish.py'
spec=importlib.util.spec_from_file_location('secret_metadata_conflict',path)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
try:
    home=m.home_for_self()
    for source in (home/'dotfiles/env.secret.sh',home/'.config/secrets/env.sh'):
        st=m.checked_path(source,os.getuid())
        assert not st.st_mode & 0o077
        m.secret_safe(source,os.getuid())
except Exception:
    sys.exit(1)
PY_SECRET_CONFLICT
    then info secrets-source "both safe export files retained; explicitly import legacy before retirement"
    else bad secrets-source "unsafe shell export metadata (usr secrets-migrate --self)"; fi
  else
    case "$secret_source_check" in
      *"already migrated"*) ok secrets-source "canonical shell exports pass metadata/ACL checks" ;;
      *"would back up"*|*"need masked ACL cleanup"*) info secrets-source "shell export migration/ACL cleanup awaits usr secrets-migrate --self" ;;
      *) info secrets-source "shell exports are not configured" ;;
    esac
  fi
  # profile links of the managed users point at /srv/dotfiles
  users_nolink=""
  for u in $(managed_users profile); do
    h=$(getent passwd "$u" | cut -d: -f6)
    [ -n "$h" ] && [ -d "$h" ] || continue
    [ "$(readlink "$h/.zshrc" 2>/dev/null)" = /srv/dotfiles/.zshrc ] || users_nolink="$users_nolink $u"
    [ "$(readlink "$h/.local/bin/db" 2>/dev/null)" = /srv/dotfiles/.local/bin/db ] || users_nolink="$users_nolink $u(dev launchers)"
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
  # shared dev tools (USERS-SYNC): /srv/devtools holds exactly the pinned versions, owned by the owner (or root) and not
  # writable by group/other; td and yc put /srv/devtools/bin on their PATH only while that holds. INFO until the tree exists.
  if [ -d /srv/devtools ]; then
    users_dt_bad=""
    users_dt_owner="$(stat -c %U /srv/devtools)"
    { [ "$users_dt_owner" = "$USER" ] || [ "$users_dt_owner" = root ]; } || users_dt_bad="$users_dt_bad owner($users_dt_owner)"
    [ "$(cat /srv/devtools/.owner 2>/dev/null)" = "$USER" ] || users_dt_bad="$users_dt_bad .owner(missing or not $USER: sudo ./apply-system.sh --only users)"
    users_dt_w="$(find /srv/devtools -xdev ! -type l -perm /022 2>/dev/null | head -3 | paste -sd' ' -)"
    [ -z "$users_dt_w" ] || users_dt_bad="$users_dt_bad group/other-writable($users_dt_w)"
    if [ -z "$users_dt_bad" ]; then
      if users_dt_out="$("$DOTFILES/infrastructure/dev/user-tools.sh" --shared --check 2>&1)"; then
        ok users-devtools "/srv/devtools holds the pinned dev tools ($(ls /srv/devtools/bin 2>/dev/null | paste -sd' ' -)), $USER-owned, nobody else can write"
      else
        bad users-devtools "/srv/devtools is not current: $(printf '%s' "$users_dt_out" | paste -sd';' -) (infrastructure/dev/user-tools.sh --shared)"
      fi
    else
      bad users-devtools "/srv/devtools:$users_dt_bad"
    fi
  else
    info users-devtools "/srv/devtools does not exist yet (sudo ./apply-system.sh --only users; the section starts the fill, or run usr devtools-sync)"
  fi
  # the root-owned anchor of the /srv/devtools PATH rule (.owner alone can be written by the account that owns the tree)
  if [ -e /etc/usr-managed/devtools-owner ]; then
    if [ "$(cat /etc/usr-managed/devtools-owner 2>/dev/null)" = "$USER" ] && [ "$(stat -c '%U %G %a' /etc/usr-managed/devtools-owner)" = "root root 644" ] && [ "$(stat -c '%U %a' /etc/usr-managed/)" = "root 755" ]; then
      ok users-devtools-anchor "/etc/usr-managed/devtools-owner names $USER (root:root 644)"
    else
      bad users-devtools-anchor "/etc/usr-managed/devtools-owner is not 'root root 644' naming $USER (sudo ./apply-system.sh --only users)"
    fi
  elif [ -d /srv/devtools ]; then
    info users-devtools-anchor "/etc/usr-managed/devtools-owner is missing: the PATH rule still trusts /srv/devtools/.owner (sudo ./apply-system.sh --only users)"
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
if sc_copy_out="$("$DOTFILES/infrastructure/tests/selfcopy/run.sh" 2>&1)"; then ok selfcopy-tests "doctor/apply-system private copy: removed on Ctrl+C and SIGTERM, /tmp as root: $(printf '%s' "$sc_copy_out" | tail -1)"; else bad selfcopy-tests "$(printf '%s' "$sc_copy_out" | grep -m1 '^FAIL') (infrastructure/tests/selfcopy/run.sh)"; fi
# FIX5: the suites must not leave Python bytecode in the repo (python3 -I ignores PYTHONPYCACHEPREFIX; -B / PYTHONDONTWRITEBYTECODE do not)
if hy_out="$("$DOTFILES/infrastructure/tests/hygiene/run.sh" --quick 2>&1)"; then ok hygiene-tests "test suites leave no __pycache__ in the repo: $(printf '%s' "$hy_out" | tail -1)"; else bad hygiene-tests "$(printf '%s' "$hy_out" | grep -m1 '^FAIL') (infrastructure/tests/hygiene/run.sh)"; fi
if edit_out="$("$DOTFILES/infrastructure/tests/edit/run.sh" 2>&1)"; then ok edit-tests "edit anywhere (SUPER+CTRL+E): $(printf '%s' "$edit_out" | tail -1)"; else bad edit-tests "$(printf '%s' "$edit_out" | grep -m1 '^FAIL') (infrastructure/tests/edit/run.sh)"; fi
# edit anywhere preloads only a selection its primary-selection watcher saw being made (autostart in hyprland.lua)
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  if pgrep -u "$(id -u)" -f 'wl-paste --primary --type text --watch .*edit-anywhere.sh _seen' >/dev/null 2>&1; then ok edit-watch "primary-selection watcher runs (fresh selections are preloaded)"
  else bad edit-watch "primary-selection watcher not running, nothing is preloaded (setsid -f ~/.config/hypr/scripts/edit-anywhere.sh _watch)"; fi
fi
# DEV-a: gitleaks pre-commit hook, atuin (local history), carapace gap filler, difftastic, long-command toast
da_hp="$(git -C "$DOTFILES" config --get core.hooksPath 2>/dev/null)"
da_bad=""
[ "$da_hp" = ".githooks" ] || da_bad="$da_bad core.hooksPath is '$da_hp' (install.sh sets .githooks);"
[ -x "$DOTFILES/.githooks/pre-commit" ] || da_bad="$da_bad .githooks/pre-commit is missing or not executable;"
[ -x "$DOTFILES/.githooks/pre-push" ] || da_bad="$da_bad .githooks/pre-push is missing or not executable (commits made by merge/rebase/cherry-pick/am are only caught at push);"
[ ! -e "$DOTFILES/.gitleaksignore" ] || da_bad="$da_bad a .gitleaksignore exists (the hook refuses it, allowlist entries go into .gitleaks.toml);"
# the COMMITTED config is the one the hooks use: it must extend the default rules and hold no broad allowlist (paths, catch-all regex)
da_cfgp="$( (. "$DOTFILES/.githooks/gitleaks-lib" && gl_committed_cfg_problems "$DOTFILES") 2>/dev/null | tr '\n' ';')"
[ -z "$da_cfgp" ] || da_bad="$da_bad the committed .gitleaks.toml is too broad: $da_cfgp"
command -v gitleaks >/dev/null 2>&1 || da_bad="$da_bad gitleaks is not installed (sudo ./apply-system.sh --only install): every commit is blocked;"
if [ -z "$da_bad" ]; then
  ok gitleaks-hook "pre-commit scans the staged changes, pre-push the pushed commits (core.hooksPath=.githooks, committed .gitleaks.toml with the default rules and exact allowlists only, no .gitleaksignore)"
else
  bad gitleaks-hook "$da_bad"
fi
if [ -e "$DOTFILES/.config/nvim/.git" ]; then
  da_nv="$(git -C "$DOTFILES/.config/nvim" config --get core.hooksPath 2>/dev/null)"
  [ "$da_nv" = "$DOTFILES/.githooks" ] || info gitleaks-nvim "the nvim submodule does not use the pre-commit hook yet: git -C ~/dotfiles/.config/nvim config core.hooksPath ~/dotfiles/.githooks (install.sh does it)"
fi
if command -v gitleaks >/dev/null 2>&1; then
  da_out="$( (. "$DOTFILES/.githooks/gitleaks-lib" && gl_history_scan "$DOTFILES") 2>&1)"; da_rc=$?   # committed .gitleaks.toml, not the working file
  case $da_rc in
    0) ok gitleaks-history "no secrets in any commit of the history (default rules + the committed .gitleaks.toml allowlist; scan of tracked history only)" ;;
    3) bad gitleaks-history "gitleaks finds possible secrets in the history (values redacted): cd ~/dotfiles && gitleaks git --redact -v -c .gitleaks.toml ." ;;
    *) bad gitleaks-history "gitleaks failed to run (exit $da_rc): $(printf '%s' "$da_out" | tail -1)" ;;
  esac
else
  info gitleaks-history "gitleaks is not installed (sudo ./apply-system.sh --only install)"
fi
if command -v atuin >/dev/null 2>&1; then
  da_bad=""
  for da_kv in auto_sync=false update_check=false ai.enabled=false daemon.enabled=false logs.enabled=false; do
    [ "$(ATUIN_SESSION=doctor atuin config get -r "${da_kv%%=*}" 2>/dev/null)" = "${da_kv#*=}" ] || da_bad="$da_bad ${da_kv%%=*} is not ${da_kv#*=};"
  done
  case "$(ATUIN_SESSION=doctor atuin config get -r sync_address 2>/dev/null)" in http://127.0.0.1*) ;; *) da_bad="$da_bad sync_address is not the unroutable local address;" ;; esac
  [ ! -e "$HOME/.atuin" ] || da_bad="$da_bad ~/.atuin exists (logs.enabled must stay false);"
  pgrep -u "$(id -u)" -f 'atuin daemon' >/dev/null 2>&1 && da_bad="$da_bad an atuin daemon is running (it must stay off);"
  if [ -n "$da_bad" ]; then
    bad atuin "$da_bad (.config/atuin/config.toml)"
  elif [ -e "${XDG_DATA_HOME:-$HOME/.local/share}/atuin/history.db" ]; then
    ok atuin "local only (no sync, AI, daemon, logs), history database present; Ctrl+R lists it"
  else
    info atuin "installed, local only; the database appears (with the zsh history imported) when you open the next terminal"
  fi
else
  info atuin "not installed: sudo ./apply-system.sh --only install (Ctrl+R keeps the zsh history list meanwhile)"
fi
if [ -r "$DOTFILES/.config/zsh/completion.zsh" ] && grep -q 'compdef _df_carapace_default -default-' "$DOTFILES/.config/zsh/completion.zsh" && grep -q 'completion' "$DOTFILES/.zshrc"; then
  if command -v carapace >/dev/null 2>&1; then
    da_cc="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/carapace.zsh"
    if [ ! -e "$da_cc" ]; then info carapace "installed; the completion cache is built on the first Tab of a command without a zsh completion (lazygit, glab, k9s, ...)"
    elif [ "$(command -v carapace)" -nt "$da_cc" ]; then info carapace "completion cache is older than the carapace binary; it is rebuilt on the next use"
    elif zsh -n "$da_cc" 2>/dev/null; then ok carapace "gap filler for commands without a zsh completion (-default-), cache is current and valid zsh"
    else bad carapace "$da_cc is not valid zsh (delete it, it is rebuilt)"; fi
  else
    info carapace "not installed (AUR carapace-bin: sudo ./apply-system.sh --only install); the completion menu works without it"
  fi
else
  bad carapace "completion.zsh or its .zshrc hook is missing (-default- gap filler)"
fi
da_bad=""
[ "$(git -C "$DOTFILES" config --get difftool.difftastic.cmd 2>/dev/null)" = 'difft "$LOCAL" "$REMOTE"' ] || da_bad="$da_bad .gitconfig difftool.difftastic.cmd;"
git -C "$DOTFILES" config -f "$DOTFILES/.gitconfig" --get alias.dlog >/dev/null 2>&1 || da_bad="$da_bad .gitconfig alias dlog;"
grep -q 'name: difftastic' "$DOTFILES/.config/lazygit/config.yml" 2>/dev/null || da_bad="$da_bad the lazygit difftastic renderer;"
if [ -n "$da_bad" ]; then bad difftastic "missing:$da_bad"
elif command -v difft >/dev/null 2>&1; then ok difftastic "git dft / dlog / dshow and the lazygit renderer are configured, difft installed ($(difft --version 2>/dev/null | head -1))"
else info difftastic "configured, but difft is not installed (sudo ./apply-system.sh --only install); lazygit shows an error only when you cycle to it"; fi
da_bad=""
[ -x "$DOTFILES/.config/hypr/scripts/cmd-notify.sh" ] || da_bad="$da_bad cmd-notify.sh is not executable;"
[ -r "$DOTFILES/.config/zsh/cmd-hooks.zsh" ] && grep -q 'add-zsh-hook precmd _df_cmd_precmd' "$DOTFILES/.config/zsh/cmd-hooks.zsh" || da_bad="$da_bad cmd-hooks.zsh has no precmd hook;"
grep -q 'cmd-hooks history completion' "$DOTFILES/.zshrc" 2>/dev/null || da_bad="$da_bad .zshrc does not source the hook files;"
[ "$(readlink -f "$HOME/.config/zsh/cmd-hooks.zsh" 2>/dev/null)" = "$(readlink -f "$DOTFILES/.config/zsh/cmd-hooks.zsh")" ] || da_bad="$da_bad cmd-hooks.zsh is not linked into ~/.config/zsh (cd ~/dotfiles && stow .);"
command -v jq >/dev/null 2>&1 || da_bad="$da_bad jq is missing;"
if [ -n "$da_bad" ]; then bad cmd-notify "$da_bad"
elif [ -e "${XDG_STATE_HOME:-$HOME/.local/state}/cmd-notify/off" ]; then info cmd-notify "installed, switched off (hub row Long-command notifications)"
else ok cmd-notify "long-command toast installed (>= 30 s, terminal not in front; hub toggle, state file read live)"; fi
if da_t="$("$DOTFILES/infrastructure/tests/dev-a/run.sh" --quick 2>&1)"; then ok dev-a-tests "gitleaks hook, atuin, carapace, cmd-notify, hook overhead: $(printf '%s' "$da_t" | tail -1)"; else bad dev-a-tests "$(printf '%s' "$da_t" | grep -m1 '^FAIL') (infrastructure/tests/dev-a/run.sh)"; fi
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
# Secret Service for the Bitwarden desktop app: pam_oo7 (greetd) can only unlock the Login collection when oo7-daemon
# already runs at the login, so the unit must be enabled (linger starts it at boot)
if [ -x /usr/lib/oo7-daemon ]; then
  if [ "$(systemctl --user is-enabled oo7-daemon.service 2>/dev/null)" = enabled ]; then ok oo7-daemon "oo7-daemon.service enabled (runs before the login, pam_oo7 unlocks the Login collection)"
  else bad oo7-daemon "oo7-daemon.service is not enabled: the Login collection stays locked and the Bitwarden app spins (systemctl --user enable --now oo7-daemon.service, then log in again)"; fi
fi
# stop timeouts (a hanging service must not hold a reboot): the owner's user manager reads user.conf.d (stowed), the
# system side comes from apply-system.sh --only config
st_bad=""
[ "$(systemctl --user show -p DefaultTimeoutStopUSec --value 2>/dev/null)" = 10s ] || st_bad="$st_bad user manager default stop timeout is not 10 s (stow ., systemctl --user daemon-reexec);"
for st_f in "stop-timeout.conf:/etc/systemd/system.conf.d/10-dotfiles-stop-timeout.conf" "user-at-stop-timeout.conf:/etc/systemd/system/user@.service.d/10-dotfiles-stop-timeout.conf" "user-manager-stop-timeout.conf:/etc/systemd/user.conf.d/10-dotfiles-stop-timeout.conf"; do
  cmp -s "$DOTFILES/infrastructure/systemd/${st_f%%:*}" "${st_f#*:}" || st_bad="$st_bad ${st_f#*:} differs or is missing;"
done
if [ -z "$st_bad" ]; then ok stop-timeouts "user units 10 s, system units 20 s, user managers 30 s"
elif [ ! -e /etc/systemd/system.conf.d/10-dotfiles-stop-timeout.conf ]; then info stop-timeouts "${st_bad# } (sudo ./apply-system.sh --only config)"
else bad stop-timeouts "${st_bad# } (sudo ./apply-system.sh --only config)"; fi
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

# ── DEV-b: mise (tool versions per project, replaces direnv) and envs (per-project secrets from Bitwarden) ───────
if command -v mise >/dev/null 2>&1; then info mise "installed ($(mise --version 2>/dev/null | head -1))"; else info mise "not installed (sudo ~/dotfiles/apply-system.sh --only install; .config/zsh/mise.zsh returns at once without it)"; fi
db_bad=""
grep -q 'direnv hook' "$DOTFILES/.zshrc" 2>/dev/null && db_bad="$db_bad .zshrc still has the direnv hook;"
grep -q 'zsh/mise.zsh' "$DOTFILES/.zshrc" 2>/dev/null || db_bad="$db_bad .zshrc does not source mise.zsh;"
grep -q 'zsh/envs.zsh' "$DOTFILES/.zshrc" 2>/dev/null || db_bad="$db_bad .zshrc does not source envs.zsh;"
grep -q '_ENVS_PROMPT' "$DOTFILES/.zshrc" 2>/dev/null || db_bad="$db_bad the PROMPT lacks the envs marker;"
[ -r "$DOTFILES/.config/zsh/mise.zsh" ] && [ -r "$DOTFILES/.config/zsh/envs.zsh" ] || db_bad="$db_bad mise.zsh or envs.zsh is missing;"
if [ -n "$db_bad" ]; then bad mise-shell "$db_bad"; else ok mise-shell "mise.zsh (cached activation, shims for agents, auto-install on cd) and envs.zsh (prompt marker) are sourced, no direnv hook"; fi
if command -v mise >/dev/null 2>&1; then
  if [ "$(readlink -f "$HOME/.config/mise/config.toml" 2>/dev/null)" = "$(readlink -f "$DOTFILES/.config/mise/config.toml")" ]; then ok mise-config "~/.config/mise/config.toml is the stowed repo file"; else bad mise-config "~/.config/mise/config.toml is not the repo file (cd ~/dotfiles && stow .)"; fi
fi
if db_t="$("$DOTFILES/infrastructure/tests/envs/run.sh" --quick 2>&1)"; then ok envs-test "envs against the fake vault: $(printf '%s' "$db_t" | tail -1)"; else bad envs-test "$(printf '%s' "$db_t" | grep -m1 '^FAIL') (infrastructure/tests/envs/run.sh)"; fi
if "$DOTFILES/.config/hub/hub" --list --all 2>/dev/null | grep -q ' envs '; then ok envs-row "hub row envs exists (group Dev, leader j e)"; else bad envs-row "hub row envs missing (.config/hub/actions.d/dev-b.tsv)"; fi
# FIX-DEVb: the hardening of the review stays in place (absolute interpreter, absolute er/ere/ert, no legacy-file auto-install, backends off)
db_bad=""
[ "$(head -1 "$DOTFILES/.local/bin/envs")" = '#!/usr/bin/python3 -I' ] || db_bad="$db_bad envs shebang is not the absolute #!/usr/bin/python3 -I;"
grep -qF 'typeset -gr _ENVS_BIN=~${USERNAME}/.local/bin/envs' "$DOTFILES/.zshrc" || db_bad="$db_bad .zshrc does not fix _ENVS_BIN (readonly, passwd home) to ~/.local/bin/envs at startup;"
for db_f in envs er ere ert; do grep -qE "^$db_f\(\) \{.*\\\$_ENVS_BIN" "$DOTFILES/.zshrc" || db_bad="$db_bad $db_f() does not call \$_ENVS_BIN;"; done
grep -q 'MISE_AUTO_INSTALL' "$DOTFILES/.local/bin/envs" || db_bad="$db_bad envs run does not switch mise auto-install off;"
grep -q 'not installed automatically' "$DOTFILES/.config/zsh/mise.zsh" || db_bad="$db_bad mise.zsh would auto-install for legacy version files;"
grep -q '^disable_backends = \["asdf", "vfox"\]' "$DOTFILES/.config/mise/config.toml" || db_bad="$db_bad mise config does not disable the asdf/vfox backends;"
grep -q 'hook-env -s bash --force' "$DOTFILES/.local/bin/sysup" && ! grep -q 'MISE_DIFF.*json' "$DOTFILES/.local/bin/sysup" || db_bad="$db_bad sysup does not let mise undo an activated project (hook-env);"
if [ -n "$db_bad" ]; then bad envs-hardening "$db_bad"; else ok envs-hardening "envs: absolute interpreter and er/ere/ert/envs fixed at shell start, no mise auto-install under envs run, trust is its own question, install-on-cd skips legacy version files, sysup lets mise undo a project env"; fi
for db_f in ENVS_TOOL_PATH ENVS_TEST_YES ENVS_TEST_ROOT_PID RBW_BIN BW_BIN PINENTRY_BIN; do
  [ -z "$(printenv "$db_f" 2>/dev/null)" ] || info envs-hooks "$db_f is set in this shell: envs ignores test hooks outside tests/ (a project [env] may have exported it)"
done
db_dir="${XDG_STATE_HOME:-$HOME/.local/state}/envs"
if [ -d "$db_dir" ]; then
  db_bad=""
  [ "$(stat -c %a "$db_dir")" = 700 ] || db_bad="$db_bad directory is $(stat -c %a "$db_dir") (want 700);"
  while IFS= read -r db_f; do [ "$(stat -c %a "$db_f")" = 600 ] || db_bad="$db_bad $(basename "$db_f") is $(stat -c %a "$db_f") (want 600);"; done < <(find "$db_dir" -type f 2>/dev/null)
  if [ -n "$db_bad" ]; then bad envs-state "$db_bad"; else ok envs-state "~/.local/state/envs is 700, files 600 (authorization records metadata-only; ambiguous source recovery stays private)"; fi
else
  info envs-state "no ~/.local/state/envs yet (created by the first envs bind / use)"
fi

# SECRETS: this helper opens only names/policy metadata; dotenv/shell-export payloads and vaults stay closed.
if [ -r "$DOTFILES/.config/envs/metadata.py" ]; then
  db_meta=$(python3 -I -B "$DOTFILES/.config/envs/metadata.py" 2>/dev/null)
  db_meta_rc=$?
  while IFS=$'\t' read -r db_kind db_check db_message; do
    case "$db_kind" in
      OK) ok "$db_check" "$db_message" ;;
      INFO) info "$db_check" "$db_message" ;;
      FAIL) bad "$db_check" "$db_message" ;;
    esac
  done <<<"$db_meta"
  [ "$db_meta_rc" -eq 0 ] || [ -n "$db_meta" ] || bad envs-metadata "metadata validation failed; no source payload read"
else
  bad envs-metadata "public metadata helper missing (stow . / usr link USER)"
fi
if grep -q 'zsh/secrets.zsh' "$DOTFILES/.zshrc" && grep -q 'zsh/envs-wrap.zsh' "$DOTFILES/.zshrc"; then
  ok secrets-shell "canonical shell source and validated local wrappers wired at shell startup"
else
  bad secrets-shell "canonical source/wrapper wiring missing"
fi

# ── DEV-c: pj, the project picker (one tmux session per repo; replaces sessionizer.sh) ──────
if [ -x "$DOTFILES/.local/bin/pj" ]; then
  pj_out="$("$DOTFILES/.local/bin/pj" check 2>&1)"; pj_rc=$?
  if [ "$pj_rc" = 0 ]; then ok pj "pj check: $(printf '%s\n' "$pj_out" | grep -c '^PASS') ok (SUPER+P, prefix F, no sessionizer.sh, cli profile, config)"; else bad pj "$(printf '%s\n' "$pj_out" | grep -m1 '^FAIL') (pj check)"; fi
  if [ -x "$DOTFILES/infrastructure/tests/pj/run.sh" ]; then
    if pj_t="$("$DOTFILES/infrastructure/tests/pj/run.sh" --quick 2>&1)"; then ok pj-tests "offline tests: $(printf '%s' "$pj_t" | tail -1)"; else bad pj-tests "$(printf '%s' "$pj_t" | grep -m1 '^FAIL') (infrastructure/tests/pj/run.sh)"; fi
  else
    bad pj-tests "infrastructure/tests/pj/run.sh missing"
  fi
  pj_dir="${XDG_STATE_HOME:-$HOME/.local/state}/pj"
  if [ -d "$pj_dir" ]; then
    pj_bad=""
    [ "$(stat -c %a "$pj_dir")" = 700 ] || pj_bad="$pj_bad $pj_dir is $(stat -c %a "$pj_dir") (want 700);"
    [ ! -e "$pj_dir/trusted.tsv" ] || [ "$(stat -c %a "$pj_dir/trusted.tsv")" = 600 ] || pj_bad="$pj_bad trusted.tsv is $(stat -c %a "$pj_dir/trusted.tsv") (want 600);"
    pj_n="$(grep -c . "$pj_dir/trusted.tsv" 2>/dev/null)"   # grep -c prints 0 AND exits 1 on an empty file: no `|| echo 0`
    if [ -n "$pj_bad" ]; then bad pj-trust "$pj_bad"; else info pj-trust "${pj_n:-0} trusted file(s) (.tmux-session.toml and .workmux.yaml; pj trust DIR to add one); state dir 700, trusted.tsv 600"; fi
  else
    info pj-trust "no trusted layout files yet (~/.local/state/pj appears with the first pj trust)"
  fi
else
  info pj ".local/bin/pj not present"
fi

# ── DEV-d: terminal dev tools (db, api, ci, forge: lazysql, posting, hurl, gh-dash, act, glab, glab-tui, gitlab-ci-local) ──────
dd_tools=""
for dd_t in lazysql gh-dash posting hurl act glab glab-tui gitlab-ci-local; do
  dd_p="$(command -v "$dd_t" 2>/dev/null || true)"
  [ -n "$dd_p" ] || for dd_d in .local/bin go/bin .cargo/bin .npm-global/bin; do [ -x "$HOME/$dd_d/$dd_t" ] && { dd_p="$HOME/$dd_d/$dd_t"; break; }; done
  if [ -z "$dd_p" ]; then
    case "$dd_t" in hurl|act|glab) dd_h="sudo ~/dotfiles/apply-system.sh --only install" ;; *) dd_h="~/dotfiles/infrastructure/dev/user-tools.sh" ;; esac
    dd_tools="$dd_tools $dd_t missing ($dd_h);"
  else
    case "$dd_t" in
      lazysql|gh-dash) dd_v="$(go version -m "$dd_p" 2>/dev/null | awk '$1 == "mod" {print $3; exit}')" ;;
      posting) dd_v="$(pipx list --short 2>/dev/null | awk '$1 == "posting" {print $2; exit}')" ;;
      *) dd_v="$(timeout 5 "$dd_p" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)" ;;
    esac
    dd_tools="$dd_tools $dd_t ${dd_v:-?};"
  fi
done
info dev-tools "${dd_tools# }"
if [ -x "$DOTFILES/infrastructure/tests/dev/run.sh" ]; then
  if dd_t="$("$DOTFILES/infrastructure/tests/dev/run.sh" --quick 2>&1)"; then ok dev-test "dev launchers against fakes: $(printf '%s' "$dd_t" | tail -1)"; else bad dev-test "$(printf '%s' "$dd_t" | grep -m1 '^FAIL') (infrastructure/tests/dev/run.sh)"; fi
else
  bad dev-test "infrastructure/tests/dev/run.sh missing"
fi
dd_bad=""
for dd_f in lazysql.toml posting.yaml gh-dash-theme.yml glab-tui.toml; do
  for dd_v in black night; do [ -s "$DOTFILES/themes/generated/$dd_v/$dd_f" ] || dd_bad="$dd_bad themes/generated/$dd_v/$dd_f is missing (render.py);"; done
done
if command -v posting >/dev/null 2>&1 || [ -x "$HOME/.local/bin/posting" ]; then
  [ -e "$HOME/.local/share/posting/themes/everforest.yaml" ] || dd_bad="$dd_bad the posting theme link ~/.local/share/posting/themes/everforest.yaml is broken (stow .);"
  [ "$(readlink -f "$HOME/.config/posting/config.yaml" 2>/dev/null)" = "$(readlink -f "$DOTFILES/.config/posting/config.yaml")" ] || dd_bad="$dd_bad ~/.config/posting/config.yaml is not the stowed file;"
fi
if command -v glab-tui >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/glab-tui" ]; then
  [ -e "$HOME/.config/glab-tui/themes/everforest.toml" ] || dd_bad="$dd_bad the glab-tui theme link ~/.config/glab-tui/themes/everforest.toml is broken (stow .);"
fi
if [ -n "$dd_bad" ]; then bad dev-theme "$dd_bad"; else ok dev-theme "lazysql, posting, gh-dash and glab-tui outputs exist for both variants; installed tools have their theme links"; fi
dd_bad=""
grep -q 'LAZYSQL_NO_TELEMETRY=1' "$DOTFILES/.zshrc" && grep -q 'LAZYSQL_NO_UPDATE_CHECK=1' "$DOTFILES/.zshrc" || dd_bad="$dd_bad .zshrc does not export the lazysql privacy switches;"
grep -q -- '--no-telemetry' "$DOTFILES/.local/bin/db" && grep -q 'LAZYSQL_NO_UPDATE_CHECK' "$DOTFILES/.local/bin/db" || dd_bad="$dd_bad db does not pass --no-telemetry and LAZYSQL_NO_UPDATE_CHECK;"
grep -A1 '^history:' "$DOTFILES/.config/posting/config.yaml" 2>/dev/null | grep -q 'enabled: false' || dd_bad="$dd_bad the posting config does not switch its response history off (it keeps resolved URLs and bodies on disk);"
if [ -n "$dd_bad" ]; then bad dev-privacy "$dd_bad"; else ok dev-privacy "lazysql telemetry and update check off (zshrc + db), posting history off"; fi
if command -v glab >/dev/null 2>&1; then
  # read the config file, never run glab: with telemetry on it sends an event after every command and ignored the TERM
  # of `timeout 5` for minutes (doctor hung on it); offline and instant
  dd_gc="${GLAB_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/glab-cli}/config.yml"
  dd_g="$(sed -n 's/^telemetry:[[:space:]]*//p' "$dd_gc" 2>/dev/null | head -n1 | tr -d "\"'")"
  info glab-telemetry "glab config telemetry = ${dd_g:-unset (no $dd_gc or no telemetry key yet)}"
fi
if command -v gh >/dev/null 2>&1; then
  # offline: `gh auth status` asks the API; the token's storage is visible in hosts.yml (oauth_token = plaintext)
  dd_gh="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
  if grep -qs '^[[:space:]]*oauth_token:' "$dd_gh"; then dd_s="Logged in (hosts.yml)"
  elif grep -qs '^[[:space:]]*user:' "$dd_gh"; then dd_s="Logged in (keyring)"
  else dd_s=""; fi
  case "$dd_s" in
    *keyring*) info gh-token-storage "the gh token is in the keyring" ;;
    *hosts.yml*) info gh-token-storage "the gh token is in ~/.config/gh/hosts.yml (plaintext; agents use gh; moving it is owner decision Q2 of DEV-d)" ;;
    "") info gh-token-storage "gh is not logged in" ;;
    *) info gh-token-storage "$dd_s" ;;
  esac
fi
if command -v act >/dev/null 2>&1 || [ -x "$HOME/.local/bin/act" ]; then
  [ "$(readlink -f "$HOME/.config/act/actrc" 2>/dev/null)" = "$(readlink -f "$DOTFILES/.config/act/actrc")" ] && ok act-config "~/.config/act/actrc is the stowed file" || bad act-config "act is installed but ~/.config/act/actrc is not the stowed file (cd ~/dotfiles && stow .)"
fi
[ -e "$HOME/.gitlab-ci-local/variables.yml" ] && info gcl-home-vars "~/.gitlab-ci-local/variables.yml exists (a plaintext secrets file of gitlab-ci-local; existence only, not read)"
dd_g="$HOME/.config/envs"
if [ -e "$dd_g/global.toml" ]; then
  dd_bad=""
  [ "$(readlink -f "$dd_g/global.toml")" = "$(readlink -f "$DOTFILES/.config/envs/global.toml")" ] || dd_bad="$dd_bad global.toml is not the stowed file;"
  for dd_f in global.toml global.local.toml; do
    [ -e "$dd_g/$dd_f" ] || continue
    dd_m="$(stat -L -c %a "$dd_g/$dd_f")"
    [ "$(stat -L -c %u "$dd_g/$dd_f")" = "$(id -u)" ] || dd_bad="$dd_bad $dd_f is not owned by you;"
    [ $((8#$dd_m & 8#022)) = 0 ] || dd_bad="$dd_bad $dd_f is writable by group or others ($dd_m);"
  done
  [ ! -L "$dd_g" ] || dd_bad="$dd_bad ~/.config/envs is a symlink: global.local.toml would land in the repo (make it a real directory, stow .);"
  if [ -n "$dd_bad" ]; then bad envs-global "$dd_bad"; else info envs-global "global scope: global.toml linked$([ -e "$dd_g/global.local.toml" ] && echo ", global.local.toml $(stat -c %a "$dd_g/global.local.toml")" || echo ", no global.local.toml (optional)")"; fi
else
  info envs-global "no ~/.config/envs/global.toml yet (cd ~/dotfiles && stow .)"
fi

# ── DEV-e: local LLM (llm; llama.cpp on Vulkan, started on demand by llm.socket, unloaded after 5 idle minutes). Nothing here
#    connects to llm.sock: that would load the model (`llm status` reads systemd and the cached device list only) ───────────────
le_llm="$DOTFILES/.local/bin/llm"
le_srv=/usr/bin/llama-server le_vk=/usr/lib/ggml/libggml-vulkan.so
le_sd="$(systemctl --user show llm-server.service -p ActiveState --value 2>/dev/null)"
if [ -x "$le_srv" ] && [ -e "$le_vk" ]; then ok llm-pkg "llama-server and the ggml Vulkan backend are installed ($(pacman -Q llama-cpp 2>/dev/null | cut -d' ' -f2), ggml-vulkan $(pacman -Q ggml-vulkan 2>/dev/null | cut -d' ' -f2))"
elif [ -x "$le_srv" ]; then bad llm-pkg "llama-cpp is installed but $le_vk is missing: llama-server would silently run on the CPU (sudo ~/dotfiles/apply-system.sh --only install)"
else info llm-pkg "llama-cpp and ggml-vulkan are not installed (sudo ~/dotfiles/apply-system.sh --only install)"; fi
le_json=""
if [ -x "$le_llm" ] && [ -x "$le_srv" ]; then le_json="$("$le_llm" status --json 2>/dev/null)"; fi
if [ -z "$le_json" ]; then info llm-vulkan "packages missing: no device list"
elif [ "$(printf '%s' "$le_json" | jq -r '.gpu')" = true ]; then ok llm-vulkan "$(printf '%s' "$le_json" | jq -r '.devices | map(select(test("^Vulkan"))) | first')"
else bad llm-vulkan "llama-server lists no real Vulkan device ($(printf '%s' "$le_json" | jq -r '.devices | join("; ")')); it would run on the CPU or not at all"; fi
if [ -x "$le_llm" ]; then
  le_mj="$("$le_llm" status --json 2>/dev/null)"
  le_ms="$(printf '%s' "${le_mj:-{\}}" | jq -r '.model_state // "unknown"')" le_mn="$(printf '%s' "${le_mj:-{\}}" | jq -r '.model // "?"')"
  case "$le_ms" in
    fetched) ok llm-model "active model $le_mn is downloaded and unchanged since its sha256 check" ;;
    missing|partial) info llm-model "active model $le_mn is $le_ms (llm models fetch)" ;;
    *) bad llm-model "active model $le_mn is $le_ms (llm models fetch $le_mn re-verifies it)" ;;
  esac
else
  bad llm-model ".local/bin/llm missing"
fi
le_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/llm/llm.sock"
if [ ! -x "$le_srv" ]; then info llm-socket "packages missing"
else
  le_bad=""
  [ "$(systemctl --user is-enabled llm.socket 2>/dev/null)" = enabled ] || le_bad="$le_bad llm.socket is not enabled (systemctl --user enable --now llm.socket);"
  [ "$(systemctl --user is-active llm.socket 2>/dev/null)" = active ] || le_bad="$le_bad llm.socket is not listening;"
  [ -S "$le_sock" ] || le_bad="$le_bad $le_sock is missing;"
  [ -S "$le_sock" ] && [ "$(stat -c %a "$le_sock")" = 600 ] || le_bad="$le_bad socket mode is not 0600;"
  [ "$(stat -c %a "$(dirname "$le_sock")" 2>/dev/null)" = 700 ] || le_bad="$le_bad socket directory mode is not 0700;"
  if [ -z "$le_bad" ]; then ok llm-socket "llm.socket enabled and listening, socket 0600 in a 0700 directory"; else bad llm-socket "${le_bad# }"; fi
fi
le_bad=""
ss -ltnpH 2>/dev/null | grep -q 'llama-server' && le_bad="$le_bad a llama-server process listens on a TCP port;"
for le_u in "systemctl is-enabled" "systemctl --user is-enabled"; do
  case "$($le_u llama-server.service 2>/dev/null)" in enabled|enabled-runtime|linked*|alias) le_bad="$le_bad the packaged llama-server.service is enabled ($le_u): systemctl [--user] disable --now llama-server.service;" ;; esac
done
if [ -z "$le_bad" ]; then ok llm-no-tcp "no llama-server listens on TCP, the packaged llama-server.service units are not enabled"; else bad llm-no-tcp "${le_bad# }"; fi
if [ "$le_sd" = active ]; then info llm-state "loaded since $(systemctl --user show llm-server.service -p ActiveEnterTimestamp --value) ($(printf '%s' "${le_mj:-{\}}" | jq -r '.model // "?"'), MemoryCurrent $(systemctl --user show llm-server.service -p MemoryCurrent --value | awk '$1 ~ /^[0-9]+$/ {printf "%.0f MB", $1/1e6; next} {print "?"}'))"
else info llm-state "not loaded (it starts on the first request and unloads 5 minutes after the last one)"; fi
le_tf="${XDG_STATE_HOME:-$HOME/.local/state}/llm/token"
if [ -e "$le_tf" ]; then
  if [ "$(stat -c %a "$le_tf")" = 600 ] && [ "$(stat -c %a "$(dirname "$le_tf")")" = 700 ]; then ok llm-token "token file 0600 in a 0700 directory"; else bad llm-token "token file mode $(stat -c %a "$le_tf") or directory mode $(stat -c %a "$(dirname "$le_tf")") (chmod 600 / 700, or llm token rotate)"; fi
else info llm-token "no token yet (llm token ensure; the client creates it on first use)"; fi
if [ -x "$DOTFILES/infrastructure/tests/llm/run.sh" ]; then
  if le_t="$("$DOTFILES/infrastructure/tests/llm/run.sh" --quick 2>&1)"; then ok llm-tests "llm against a fake llama-server: $(printf '%s' "$le_t" | tail -1)"; else bad llm-tests "$(printf '%s' "$le_t" | grep -m1 '^FAIL') (infrastructure/tests/llm/run.sh)"; fi
else
  bad llm-tests "infrastructure/tests/llm/run.sh missing"
fi

# ── Telegram archive (tg-archive): offline suite, the export folder of the MCP service, the agent skills ──
# CLAUDE.md "Telegram archive (tg-archive)". The folder is INFO until sudo ./apply-system.sh --only mcp created it.
if [ -x "$DOTFILES/infrastructure/tests/tg-archive/run.sh" ]; then
  if ta_t="$("$DOTFILES/infrastructure/tests/tg-archive/run.sh" --quick 2>&1)"; then ok tg-archive-tests "tg-archive against a fake MCP gateway: $(printf '%s' "$ta_t" | tail -1)"; else bad tg-archive-tests "$(printf '%s' "$ta_t" | grep -m1 '^FAIL') (infrastructure/tests/tg-archive/run.sh)"; fi
else
  bad tg-archive-tests "infrastructure/tests/tg-archive/run.sh missing"
fi
if [ -d /srv/telegram-export ]; then
  ta_acl="$(getfacl -cp /srv/telegram-export 2>/dev/null || true)"
  if [ "$(stat -c %U /srv/telegram-export)" = aimcp ] && grep -qx "user:$USER:rwx" <<<"$ta_acl" \
    && grep -qx "default:user:$USER:rwx" <<<"$ta_acl" && grep -qx "other::---" <<<"$ta_acl"; then
    ok tg-export "/srv/telegram-export: written by aimcp, read and emptied by you (ACL), nobody else"
  else bad tg-export "/srv/telegram-export owner or ACL drifted (sudo ./apply-system.sh --only mcp)"; fi
else info tg-export "no export folder yet: download_media and export_history are off (sudo ./apply-system.sh --only mcp)"; fi
ta_miss=""
for ta_s in tg-archive tg-ask; do
  [ "$(readlink -f "$HOME/.claude/skills/$ta_s/SKILL.md" 2>/dev/null)" = "$DOTFILES/.config/tg-archive/skills/$ta_s/SKILL.md" ] || ta_miss="$ta_miss $ta_s"
done
if [ -z "$ta_miss" ]; then ok tg-skills "Claude Code skills /tg-archive and /tg-ask link to the repo"
else info tg-skills "skill link missing:$ta_miss (ln -s ../../../.config/tg-archive/skills/NAME ~/.claude/skills/NAME)"; fi

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
