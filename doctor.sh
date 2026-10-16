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
css_hex="$(grep -nE '#[0-9a-fA-F]{3,8}\b' "$DOTFILES/.config/waybar/style.css" 2>/dev/null | head -2 | tr '\n' ' ')"
if [ -z "$css_hex" ]; then ok bar-css "style.css uses palette tokens only"; else bad bar-css "hex literal in style.css: $css_hex"; fi
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
    cur_err="built from an older palette or PKGBUILD (sudo ~/dotfiles/apply-system.sh --only install rebuilds it)"
  fi
  if [ -z "$cur_err" ]; then
    want_fill="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["fill"].lower())' "$DOTFILES/themes/generated/black/pointer.json" 2>/dev/null)"
    unzip -p "$cur_dir/hyprcursors/left_ptr.hlc" '*.svg' 2>/dev/null | grep -qi "$want_fill" || cur_err="left_ptr fill is not $want_fill"
  fi
  if [ -z "$cur_err" ]; then ok cursor "Everforest-Cursor installed (hyprcursor + XCursor), up to date with the palette"; else bad cursor "$cur_err"; fi
  if command -v gsettings >/dev/null 2>&1; then
    cur_gs="$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null | tr -d "'")"
    if [ "$cur_gs" = Everforest-Cursor ]; then ok cursor-gtk "gsettings cursor-theme is Everforest-Cursor"; else info cursor-gtk "gsettings cursor-theme is '$cur_gs' (log in again, or run cursor-apply)"; fi
  fi
fi
if grep -q 'Everforest-Cursor' "$DOTFILES/.config/hypr/hyprland.lua"; then ok cursor-env "hyprland.lua selects Everforest-Cursor when installed, Bibata otherwise"; else bad cursor-env "hyprland.lua has no Everforest-Cursor selection"; fi

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
