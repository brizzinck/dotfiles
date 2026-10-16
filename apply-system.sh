#!/usr/bin/env bash
# Apply all root-level workstation changes (packages, /etc, services, disk, boot). Idempotent; safe to rerun.
#
#   sudo ./apply-system.sh                 run every section in order
#   sudo ./apply-system.sh --dry-run       print what each section would do, change nothing
#   sudo ./apply-system.sh --only cleanup  run a single section
#
# Section order: cleanup -> upgrade -> install -> remove -> config -> services -> disk -> boot -> flatpak -> summary
# System config files live in infrastructure/<area>/ and are installed from there (see apply-memory.sh).
set -euo pipefail

ORIG_ARGS=("$@")
DRY_RUN=0
ONLY=""
STAMP="20261016"
SECTIONS=(cleanup upgrade install remove config services disk boot flatpak summary)

usage() {
  cat <<EOF
Usage: ${0##*/} [--dry-run] [--only <section>] [-h|--help]
Sections: ${SECTIONS[*]}
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --only)
      [ $# -ge 2 ] || { echo "--only needs a section name" >&2; usage >&2; exit 2; }
      ONLY="$2"
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$ONLY" ]; then
  case " ${SECTIONS[*]} " in
    *" $ONLY "*) ;;
    *) echo "unknown section: $ONLY (valid: ${SECTIONS[*]})" >&2; exit 2 ;;
  esac
fi

# --- privileges / owner ------------------------------------------------------
# A dry run only reads, so it works unprivileged; a real run re-execs itself under sudo.
if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  exec sudo "$0" "${ORIG_ARGS[@]}"
fi

if [ "$EUID" -eq 0 ]; then
  OWNER="${SUDO_USER:-}"
  if [ -z "$OWNER" ] || [ "$OWNER" = root ]; then
    echo "run this through sudo as the workstation owner (SUDO_USER is empty or root)" >&2
    exit 1
  fi
else
  OWNER="$(id -un)"
fi
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$REPO/infrastructure"

# --- helpers -----------------------------------------------------------------
CHANGES=()
NOTES=()
FOLLOWUPS=()
REBOOT_REQUIRED=0

log() { printf '%s\n' "$*"; }
header() { printf '\n=== %s ===\n' "$*"; }
note() { NOTES+=("$*"); log "note: $*"; }
changed() { CHANGES+=("$*"); }
followup() { FOLLOWUPS+=("$*"); }
need_reboot() { REBOOT_REQUIRED=1; }

# run CMD...: execute, or only echo it in --dry-run mode.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# run_as_owner CMD...: run as the workstation owner (for user-owned paths and AUR/user tooling).
run_as_owner() {
  run sudo -u "$OWNER" -H "$@"
}

# backup_file /etc/foo: copy to /etc/foo.bak-<stamp> once, never overwrite an existing backup.
backup_file() {
  local f="$1"
  [ -e "$f" ] || return 0
  [ -e "$f.bak-$STAMP" ] && return 0
  run cp -a -- "$f" "$f.bak-$STAMP"
  log "backup: $f -> $f.bak-$STAMP"
}

# install_file SRC DEST [MODE]: install a repo file into /etc, backing up a differing original first.
install_file() {
  local src="$1" dest="$2" mode="${3:-644}"
  if [ -e "$dest" ] && cmp -s -- "$src" "$dest"; then
    log "unchanged: $dest"
    return 0
  fi
  backup_file "$dest"
  run install -Dm"$mode" -- "$src" "$dest"
  changed "installed $dest"
}

avail_kib() { df -Pk / | awk 'NR==2 {print $4}'; }

# --- cleanup -----------------------------------------------------------------
# Runs first to make room, and again after the install section (pacman-contrib provides paccache).
cleanup_pacman_cache() {
  local when="${1:-start}"
  if [ -e /var/lib/pacman/db.lck ]; then
    note "pacman database is locked, skipped pacman cache cleanup ($when)"
    return 0
  fi
  if command -v paccache >/dev/null 2>&1; then
    # keep 2 versions of installed packages for rollback, drop every cached version of uninstalled ones
    run paccache -rk2
    run paccache -ruk0
    changed "pacman cache trimmed with paccache ($when)"
  elif [ "$DRY_RUN" -eq 1 ] && [ "$when" != start ]; then
    log "[dry-run] paccache -rk2 and paccache -ruk0 would run here (pacman-contrib is installed by this section)"
  elif [ "$when" = start ]; then
    # paccache comes with pacman-contrib, which the install section adds later; until then keep installed versions only
    run pacman -Sc --noconfirm
    changed "pacman cache reduced to installed versions with pacman -Sc"
    note "paccache was missing at cleanup time; the install section reruns paccache -rk2 / -ruk0 once pacman-contrib is installed"
  else
    note "paccache is still unavailable after the install section (pacman-contrib missing), pacman cache not trimmed to 2 versions"
  fi
}

section_cleanup() {
  header "cleanup"
  local before after e
  before="$(avail_kib)"

  cleanup_pacman_cache start

  # partial download directories left by interrupted pacman runs
  if [ -d /var/cache/pacman/pkg ]; then
    run find /var/cache/pacman/pkg -maxdepth 1 -type d -name 'download-*' -mmin +60 -exec rm -rf -- {} +
    changed "stale /var/cache/pacman/pkg/download-* directories (older than 60 min) removed"
  fi

  # coredumps from the crash-looping zypak-helper (the journal keeps the crash records)
  if [ -d /var/lib/systemd/coredump ]; then
    run find /var/lib/systemd/coredump -maxdepth 1 -type f -name 'core.*' -delete
    changed "coredumps in /var/lib/systemd/coredump removed"
  fi

  # td's e2e test spool in /tmp, older than 2 hours and not held open by any process
  if id td >/dev/null 2>&1; then
    while IFS= read -r -d '' e; do
      if fuser -s -- "$e" 2>/dev/null; then
        log "skip (in use): $e"
        continue
      fi
      # a test may hold files open inside the spool without fuser seeing it: skip if anything inside changed recently
      if [ -n "$(find "$e" -mmin -120 -print -quit 2>/dev/null)" ]; then
        log "skip (modified in the last 120 min): $e"
        continue
      fi
      run rm -rf -- "$e"
    done < <(find /tmp -mindepth 1 -maxdepth 1 -user td -mmin +120 -name 'core-e2e-spool-*' -print0)
    changed "td-owned /tmp/core-e2e-spool-* (older than 120 min, not in use) removed"
  fi

  after="$(avail_kib)"
  if [ "$DRY_RUN" -eq 0 ]; then
    log "cleanup freed $(((after - before) / 1024)) MiB on /"
    changed "cleanup freed $(((after - before) / 1024)) MiB on /"
  fi
}

# --- shared helpers for the S2 sections --------------------------------------
warn() { NOTES+=("WARNING: $*"); printf 'warn: %s\n' "$*" >&2; }

# try CMD...: like run, but a failure is recorded as a warning and the script continues.
try() {
  if ! run "$@"; then
    warn "command failed: $*"
    return 0
  fi
}

pkg_installed() { pacman -Qq -- "$1" >/dev/null 2>&1; }

# sed_edit FILE SED-ARGS...: edit a file in place (backup first); echoes in --dry-run.
sed_edit() {
  local f="$1"
  shift
  backup_file "$f"
  run sed -i -E "$@" "$f"
}

# --- upgrade -----------------------------------------------------------------
section_upgrade() {
  header "upgrade"
  # full upgrade before installing anything new (partial upgrades are unsupported on Arch)
  run pacman -Syu --noconfirm
  changed "system upgraded with pacman -Syu"
  need_reboot
  followup "pacman -Qu    # should be empty after the upgrade"
}

# --- install -----------------------------------------------------------------
# Repo packages added by the workstation run. Keep in sync with the "workstation additions" block in install.sh.
# Later stages append their packages here.
REPO_PACKAGES=(
  # system
  pacman-contrib earlyoom reflector git-lfs fd smartmontools nvme-cli libva-utils amdgpu_top
  # wayland desktop helpers
  hyprpolkitagent cliphist wl-clip-persist swayosd wiremix hyprshot satty hyprpicker hyprsunset
  rofimoji wtype udiskie qt6ct
  # cli tools (shellcheck comes from the AUR as shellcheck-bin, see AUR_PACKAGES)
  bat eza git-delta github-cli trash-cli dust duf watchexec just go-yq xh shfmt direnv
  dive hyperfine
  # phase 2: OCR (rus+eng), QR/barcodes, monitor brightness over DDC/CI, ports, calculator, GIF, cleanup, timers, network
  tesseract tesseract-data-eng tesseract-data-rus zbar qrencode ddcutil pik
  libqalculate rofi-calc gifski kondo lostfiles termdown bandwhich lsof
  # TLP profiles daemon: power-profiles-daemon D-Bus API backed by TLP (tlpctl); needs tlp, conflicts with power-profiles-daemon
  tlp-pd
  # phase 2 U5: Bitwarden/Vaultwarden client (rbw) with a rofi front end; pinentry-qt (themed by qt6ct) needs kwindowsystem
  rbw rofi-rbw kwindowsystem
  # phase 2 U6: official Bitwarden desktop app (SSH agent, Wayland). The CLI (bw) is the AUR package bitwarden-cli-bin:
  # the repo bitwarden-cli needs nodejs-lts-jod, which conflicts with the installed nodejs and aborts the transaction.
  # The desktop package hard-depends on org.freedesktop.secrets; with no provider installed pacman --noconfirm would pick one
  # at random (chipass came first). oo7 is the smallest provider (no deps, D-Bus activated, no PAM/keyring setup, not
  # gnome-keyring); the app itself keeps its vault keys in the kernel keyring, not in a Secret Service.
  oo7 bitwarden
)
# AUR packages, built at run time as the owner (makepkg refuses root) and installed with pacman -U. A failure only warns.
# Keep in sync with the AUR section of install.sh. shellcheck-bin replaces the repo shellcheck (see swap_shellcheck).
AUR_PACKAGES=(bibata-cursor-theme-bin shellcheck-bin ccusage wayscrollshot-bin pacseek bitwarden-cli-bin)

cpu_ucode_package() {
  if grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
    echo amd-ucode
  elif grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
    echo intel-ucode
  fi
  return 0
}

# aur_unmet_deps SRCINFO: print the dependencies (depends + makedepends, version constraints stripped) of a
# .SRCINFO that are not satisfied on this system. makepkg without -s fails on missing dependencies, so these are
# installed from the repositories first.
aur_unmet_deps() {
  local srcinfo="$1" deps=()
  mapfile -t deps < <(sed -nE 's/^[[:space:]]*(make)?depends(_[a-z0-9_]+)? = ([^<>=[:space:]]+).*/\3/p' "$srcinfo" | sort -u)
  [ "${#deps[@]}" -gt 0 ] || return 0
  pacman -T -- "${deps[@]}" || true
}

# swap_shellcheck BUILT_PKG: replace the repo shellcheck (and its haskell dependency chain) by shellcheck-bin.
# -Rdd and -U run back to back so there is no window without shellcheck; if -U fails the repo package is restored.
# The haskell packages become orphans and go with the orphan step of the remove section.
swap_shellcheck() {
  local built="$1"
  log "replacing repo shellcheck by shellcheck-bin (pacman -Rdd, then pacman -U)"
  if pacman -Rdd --noconfirm shellcheck && pacman -U --noconfirm "$built"; then
    changed "installed AUR package shellcheck-bin (replaced repo shellcheck; haskell dependencies become orphans)"
  else
    warn "shellcheck-bin swap failed, restoring the repo shellcheck"
    pkg_installed shellcheck-bin || try pacman -S --needed --noconfirm shellcheck
  fi
}

# install_aur_package PKG: clone and build as the owner, install the dependencies the build needs, install the result
# as root. Skips installed packages. Never aborts the run.
install_aur_package() {
  local pkg="$1" build_dir unmet=() built
  if pkg_installed "$pkg"; then
    log "unchanged: $pkg already installed"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would build $pkg from https://aur.archlinux.org/$pkg.git as $OWNER (makepkg, no -s), first installing its unmet repo dependencies (pacman -S --asdeps), then pacman -U the result"
    if [ "$pkg" = shellcheck-bin ] && pkg_installed shellcheck; then
      log "[dry-run] would then run: pacman -Rdd --noconfirm shellcheck && pacman -U --noconfirm <shellcheck-bin package> (repo shellcheck replaced; its haskell dependencies go with the orphan step)"
    fi
    return 0
  fi
  build_dir="$(mktemp -d /tmp/aur-build.XXXXXX)"
  chown "$OWNER": "$build_dir"
  # shellcheck disable=SC2016  # the script runs in the owner's shell, $1 and $2 must stay literal here
  if ! run_as_owner bash -c '
      set -euo pipefail
      cd "$1"
      mkdir out
      git clone --depth 1 "https://aur.archlinux.org/$2.git" src
      cd src
      makepkg --printsrcinfo >../srcinfo
    ' _ "$build_dir" "$pkg"; then
    warn "fetching $pkg from the AUR failed, continuing without it"
    rm -rf -- "$build_dir"
    return 0
  fi
  mapfile -t unmet < <(aur_unmet_deps "$build_dir/srcinfo")
  if [ "${#unmet[@]}" -gt 0 ]; then
    log "$pkg needs from the repositories: ${unmet[*]}"
    if ! pacman -S --needed --asdeps --noconfirm -- "${unmet[@]}"; then
      warn "dependencies of $pkg (${unmet[*]}) could not be installed (AUR-only?), skipped $pkg"
      rm -rf -- "$build_dir"
      return 0
    fi
  fi
  # shellcheck disable=SC2016  # the script runs in the owner's shell, $1 must stay literal here
  if run_as_owner bash -c 'cd "$1/src" && PKGDEST="$1/out" makepkg --noconfirm' _ "$build_dir"; then
    built="$(find "$build_dir/out" -maxdepth 1 -name "$pkg-*.pkg.tar.*" ! -name '*.sig' -print -quit)"
    if [ -z "$built" ]; then
      warn "build of $pkg produced no package file, continuing without it"
    elif [ "$pkg" = shellcheck-bin ] && pkg_installed shellcheck; then
      swap_shellcheck "$built"
    elif pacman -U --noconfirm "$built"; then
      changed "installed AUR package $pkg"
    else
      warn "built $pkg but pacman -U failed"
    fi
  else
    warn "building $pkg failed, continuing without it"
  fi
  rm -rf -- "$build_dir"
}

install_aur_packages() {
  local pkg
  if ! command -v makepkg >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    warn "makepkg or git missing, skipped the AUR packages ${AUR_PACKAGES[*]} (install base-devel and git, then rerun --only install)"
    return 0
  fi
  for pkg in "${AUR_PACKAGES[@]}"; do
    install_aur_package "$pkg"
  done
}

section_install() {
  header "install"
  local ucode p wanted=() missing=()
  ucode="$(cpu_ucode_package)"
  if [ -n "$ucode" ]; then
    log "CPU microcode package for this machine: $ucode"
    REPO_PACKAGES=("$ucode" "${REPO_PACKAGES[@]}")
  else
    note "CPU vendor not recognised, no microcode package selected"
  fi

  # verify every package against the sync databases first; unknown names are dropped and reported
  for p in "${REPO_PACKAGES[@]}"; do
    if pacman -Si -- "$p" >/dev/null 2>&1; then
      wanted+=("$p")
    else
      missing+=("$p")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "not found in the repositories, dropped: ${missing[*]}"
  fi
  log "installing ${#wanted[@]} repo packages (already installed ones are skipped)"
  try pacman -S --needed --noconfirm "${wanted[@]}"
  changed "repo packages ensured (${#wanted[@]} names)"

  install_aur_packages

  # pacman-contrib (paccache) exists now; trim the cache again after the downloads
  cleanup_pacman_cache post-install
  followup "vainfo    # VA-API decode check (libva-utils)"
  followup "tesseract --list-langs    # expect eng and rus"
  followup "pacman -Q shellcheck-bin ccusage wayscrollshot-bin pacseek    # AUR builds; a missing one failed (see warnings), rerun --only install"
}

# --- remove ------------------------------------------------------------------
remove_snap_stack() {
  local s present=()
  if ! pkg_installed snapd; then
    log "snapd not installed, snap stack already gone"
    if [ -d "$OWNER_HOME/snap" ]; then
      run rm -rf -- "$OWNER_HOME/snap"
      changed "removed leftover $OWNER_HOME/snap"
    fi
    return 0
  fi
  if command -v snap >/dev/null 2>&1; then
    for s in surfshark gnome-3-28-1804 gtk-common-themes core18 core20 bare; do
      snap list "$s" >/dev/null 2>&1 && present+=("$s")
    done
    # surfshark first: the others are its bases/platforms; the flatpak Surfshark stays
    if [[ " ${present[*]} " == *" surfshark "* ]]; then
      try snap remove --purge surfshark
    fi
    for s in gnome-3-28-1804 gtk-common-themes core18 core20 bare; do
      if [[ " ${present[*]} " == *" $s "* ]]; then
        try snap remove --purge "$s"
      fi
    done
  fi
  try systemctl disable --now snapd.service snapd.socket snapd.apparmor.service
  try pacman -Rns --noconfirm snapd
  changed "snap stack and snapd removed"
  if [ -d "$OWNER_HOME/snap" ]; then
    run rm -rf -- "$OWNER_HOME/snap"
    changed "removed $OWNER_HOME/snap"
  fi
  if [ -d /var/lib/snapd ]; then
    note "/var/lib/snapd still exists after removing snapd; inspect it and delete it by hand if it holds no snaps"
  fi
}

# unit_keep_reason PKG: print "<unit> is enabled|active" for the first systemd unit shipped by PKG that is enabled or
# active (system units, then the owner's user units); print nothing otherwise. Probe failures count as not enabled.
unit_keep_reason() {
  local pkg="$1" path unit state
  while IFS= read -r path; do
    unit="${path##*/}"
    case "$unit" in *@.*) continue ;; esac
    if [[ "$path" == /usr/lib/systemd/system/* ]]; then
      state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      case "$state" in enabled | enabled-runtime) echo "$unit is enabled"; return 0 ;; esac
      if systemctl is-active --quiet "$unit" 2>/dev/null; then echo "$unit is active"; return 0; fi
    else
      state="$(user_systemctl is-enabled "$unit" 2>/dev/null || true)"
      case "$state" in enabled | enabled-runtime) echo "$unit is enabled"; return 0 ;; esac
      state="$(systemctl --global is-enabled "$unit" 2>/dev/null || true)"
      case "$state" in enabled | enabled-runtime) echo "$unit is enabled"; return 0 ;; esac
      if user_systemctl is-active --quiet "$unit" 2>/dev/null; then echo "$unit is active"; return 0; fi
    fi
  done < <(pacman -Qlq -- "$pkg" 2>/dev/null | grep -E '/usr/lib/systemd/(system|user)/[^/]+\.(service|socket|timer)$' || true)
  return 0
}

# user_systemctl ARGS...: systemctl --user against the owner's manager (works as root via runuser, or as the owner).
user_systemctl() {
  local uid_owner
  uid_owner="$(id -u "$OWNER" 2>/dev/null || true)"
  if [ "$EUID" -eq 0 ]; then
    runuser -u "$OWNER" -- env XDG_RUNTIME_DIR="/run/user/${uid_owner:-0}" systemctl --user "$@"
  else
    systemctl --user "$@"
  fi
}

section_remove() {
  header "remove"
  local p present=() orphans=() kept=() candidates=() reason

  remove_snap_stack

  # explicit list from the package review (only those actually installed).
  # kotlin is the only package that requires jdk-openjdk; no java/gradle/maven usage was found (no shell history,
  # ~/.gradle, ~/.m2 or project files), so the JDK goes with it. To keep java: pacman -D --asexplicit jdk-openjdk
  for p in lazarus fpc fpc-src kotlin zig dolphin-emu modemmanager; do
    pkg_installed "$p" && present+=("$p")
  done
  if [ "${#present[@]}" -gt 0 ]; then
    log "removing: ${present[*]}"
    try pacman -Rns --noconfirm "${present[@]}"
    changed "removed packages: ${present[*]}"
  else
    log "none of the unused toolchain packages are installed"
  fi

  # orphans last, after the removals above may have created new ones; printed before removal.
  # An orphan that ships an enabled or active systemd unit is a deliberately used service (e.g. v2ray): keep it by
  # marking it explicitly installed instead of removing it.
  mapfile -t candidates < <(pacman -Qdtq 2>/dev/null || true)
  for p in "${candidates[@]}"; do
    [ -n "$p" ] || continue
    reason="$(unit_keep_reason "$p")"
    if [ -n "$reason" ]; then
      log "keeping $p: unit $reason"
      run pacman -D --asexplicit "$p"
      changed "kept orphan $p (marked explicit): unit $reason"
      kept+=("$p")
    else
      orphans+=("$p")
    fi
  done
  if [ "${#orphans[@]}" -gt 0 ]; then
    log "orphans to remove:"
    printf '  %s\n' "${orphans[@]}"
    try pacman -Rns --noconfirm "${orphans[@]}"
    changed "removed orphans: ${orphans[*]}"
  else
    log "no orphan packages to remove"
  fi
}

# --- config ------------------------------------------------------------------
# Render a template (@OWNER@, @DOTFILES@) to a temp file and install it, so tracked files stay user-agnostic.
install_pkglist_helper() {
  local tmp
  tmp="$(mktemp)"
  sed -e "s|@OWNER@|$OWNER|g" -e "s|@DOTFILES@|$REPO|g" "$INFRA/pacman/dotfiles-pkglist.in" >"$tmp"
  install_file "$tmp" /usr/local/bin/dotfiles-pkglist 755
  rm -f -- "$tmp"
}

section_config() {
  header "config"

  # earlyoom: earlyoom.service reads EARLYOOM_ARGS through EnvironmentFile=-/etc/default/earlyoom
  install_file "$INFRA/memory/earlyoom" /etc/default/earlyoom

  # docker daemon.json (log options + BuildKit GC cap). Single source: infrastructure/memory/docker-daemon.json
  if command -v dockerd >/dev/null 2>&1 && ! dockerd --validate --config-file "$INFRA/memory/docker-daemon.json" >/dev/null 2>&1; then
    warn "dockerd --validate rejected infrastructure/memory/docker-daemon.json, /etc/docker/daemon.json left untouched"
  else
    if command -v dockerd >/dev/null 2>&1; then log "dockerd --validate: configuration OK"; fi
    install_file "$INFRA/memory/docker-daemon.json" /etc/docker/daemon.json
  fi

  # pacman hooks and the package-list snapshot helper
  install_file "$INFRA/pacman/zz-paccache.hook" /etc/pacman.d/hooks/zz-paccache.hook
  install_file "$INFRA/pacman/zz-dotfiles-pkglist.hook" /etc/pacman.d/hooks/zz-dotfiles-pkglist.hook
  install_pkglist_helper

  # makepkg: stop generating *-debug packages
  if grep -qE '^OPTIONS=\(.*[ (]debug[ )]' /etc/makepkg.conf; then
    sed_edit /etc/makepkg.conf 's/^(OPTIONS=\(.*[ (])debug([ )])/\1!debug\2/'
    changed "makepkg.conf: debug -> !debug"
  else
    log "unchanged: makepkg.conf already has !debug"
  fi

  # pacman.conf: Color and VerbosePkgLists
  if grep -qE '^#(Color|VerbosePkgLists)$' /etc/pacman.conf; then
    sed_edit /etc/pacman.conf 's/^#(Color|VerbosePkgLists)$/\1/'
    changed "pacman.conf: Color and VerbosePkgLists enabled"
  else
    log "unchanged: pacman.conf Color/VerbosePkgLists already active"
  fi

  # coredump limits
  install_file "$INFRA/systemd/coredump-limits.conf" /etc/systemd/coredump.conf.d/limits.conf

  # TLP drop-in (61-battery-care.conf only sets STOP_CHARGE_THRESH_*, no overlap with these keys)
  install_file "$INFRA/tlp/62-power.conf" /etc/tlp.d/62-power.conf

  config_i2c
}

# DDC/CI access for ddcutil (external monitor brightness). ddcutil ships a uaccess udev rule and i2c-tools (its
# dependency) ships 45-i2c-tools.rules (GROUP=i2c, MODE=0660), the sysusers entry for group i2c and its own
# modules-load entry. Uaccess alone gives intermittent EACCES on Arch, so the owner also joins the group.
config_i2c() {
  install_file "$INFRA/i2c/i2c-dev.conf" /etc/modules-load.d/i2c-dev.conf
  if ! lsmod | grep -q '^i2c_dev'; then
    try modprobe i2c-dev
  fi
  if ! getent group i2c >/dev/null; then
    try groupadd -r i2c
    changed "created system group i2c"
  fi
  if id -nG "$OWNER" | tr ' ' '\n' | grep -qx i2c; then
    log "unchanged: $OWNER is already in group i2c"
  else
    try usermod -aG i2c "$OWNER"
    changed "added $OWNER to group i2c (needs a re-login to take effect)"
    followup "re-login (or reboot) so the new group i2c applies; check: id -nG | tr ' ' '\n' | grep -x i2c"
  fi
  # apply the group rule to the device nodes that already exist
  if compgen -G '/dev/i2c-*' >/dev/null; then
    try udevadm trigger --subsystem-match=i2c-dev --action=change
  fi
  followup "ddcutil detect    # lists DDC/CI monitors; the laptop panel is not listed, an external one over HDMI/DP is"
}

# --- services ----------------------------------------------------------------
docker_config_stale() {
  local started conf_time start_time
  if ! cmp -s -- "$INFRA/memory/docker-daemon.json" /etc/docker/daemon.json 2>/dev/null; then
    return 0
  fi
  started="$(systemctl show -p ActiveEnterTimestamp --value docker.service)"
  [ -n "$started" ] || return 1
  conf_time="$(stat -c %Y /etc/docker/daemon.json)"
  start_time="$(date -d "$started" +%s)"
  [ "$conf_time" -gt "$start_time" ]
}

section_services() {
  header "services"
  run systemctl daemon-reload
  local u
  # tlp-pd.service (TLP Profiles Daemon) is D-Bus activated and sits next to tlp.service: it only runs "tlp <profile>"
  # for profile switches (tlpctl), the *_ON_AC/BAT values of /etc/tlp.d/62-power.conf stay the defaults
  for u in fstrim.timer paccache.timer reflector.timer earlyoom.service tlp-pd.service; do
    # one unit at a time: a missing unit (for example after a failed install) must not cancel the others
    try systemctl enable --now "$u"
  done
  changed "enabled fstrim.timer paccache.timer reflector.timer earlyoom.service tlp-pd.service (per unit, failures are warnings)"
  if pkg_installed power-profiles-daemon; then
    warn "power-profiles-daemon is installed and owns the same D-Bus names as tlp-pd (the packages conflict); remove it"
  fi

  # docker reads daemon.json only at start and a restart now would stop containers without a restart policy: no restart here
  if systemctl is-active --quiet docker.service && docker_config_stale; then
    note "restart docker or reboot to apply daemon.json (BuildKit GC cap); the reboot at the end of this run applies it"
    followup "after reboot: docker info --format '{{json .BuilderGC}}' 2>/dev/null; docker start pgadmin   # restart=no container"
  else
    log "docker restart not needed (daemon.json already applied or docker is not running)"
  fi

  if command -v tlp >/dev/null 2>&1; then
    try tlp start
    changed "tlp start (applied /etc/tlp.d/62-power.conf)"
  fi

  # reflector: read-only sanity check of the shipped configuration
  if [ -r /etc/xdg/reflector/reflector.conf ]; then
    log "reflector.conf (active options):"
    grep -vE '^[[:space:]]*(#|$)' /etc/xdg/reflector/reflector.conf | sed 's/^/  /'
    note "reflector.conf has no --country filter: mirrors are chosen worldwide by age; add --country to /etc/xdg/reflector/reflector.conf if pacman downloads feel slow"
  else
    warn "/etc/xdg/reflector/reflector.conf is missing, reflector.timer will use defaults"
  fi
  followup "systemctl --failed    # expect no failed units"
  followup "journalctl -u earlyoom -b --no-pager | tail    # earlyoom started with the new arguments"
  followup "systemctl list-timers fstrim.timer paccache.timer reflector.timer"
  followup "tlpctl list; tlpctl get    # TLP Profiles Daemon (powerprofilesctl-compatible D-Bus API, no powerprofilesctl binary); busctl introspect org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles"
}

# --- disk --------------------------------------------------------------------
section_disk() {
  header "disk"
  local src uuid fstype blocks reserved line

  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  uuid="$(findmnt -no UUID / 2>/dev/null || true)"
  fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  log "root: source=$src uuid=$uuid fstype=$fstype"
  if [ "$fstype" != ext4 ] || [ -z "$uuid" ] || [ -z "$src" ]; then
    note "root filesystem is not ext4 or its UUID is unknown, disk section skipped"
    return 0
  fi

  # reserved blocks: the 5% default is wasteful on a single-user root, 1% is enough
  if [ "$EUID" -eq 0 ]; then
    blocks="$(tune2fs -l "$src" | awk -F: '/^Block count/ {gsub(/ /, "", $2); print $2}')"
    reserved="$(tune2fs -l "$src" | awk -F: '/^Reserved block count/ {gsub(/ /, "", $2); print $2}')"
    if [ -n "$blocks" ] && [ -n "$reserved" ] && [ $((reserved * 100)) -gt "$blocks" ]; then
      run tune2fs -m 1 "$src"
      changed "tune2fs -m 1 $src (reserved blocks $reserved of $blocks -> 1%)"
    else
      log "unchanged: reserved blocks already <= 1% ($reserved of $blocks)"
    fi
  else
    log "[dry-run] would read tune2fs -l $src and run tune2fs -m 1 if the reserved share is above 1%"
  fi

  # fstab: relatime -> noatime,lazytime on the root line, matched by the root UUID
  line="$(awk -v u="UUID=$uuid" '$1 == u && $2 == "/" {print}' /etc/fstab)"
  if [ -z "$line" ]; then
    note "no UUID=$uuid line for / in /etc/fstab, mount options not changed"
  elif [[ "$line" == *noatime* ]]; then
    log "unchanged: root fstab line already has noatime"
  elif [[ "$line" != *relatime* ]]; then
    note "root fstab line has no relatime option to replace, not changed: $line"
  else
    backup_file /etc/fstab
    run sed -i -E "/^UUID=${uuid}[[:space:]]+\\/[[:space:]]/ s/([[:space:],])relatime([[:space:],])/\\1noatime,lazytime\\2/" /etc/fstab
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] would verify with findmnt --verify and restore /etc/fstab.bak-$STAMP on failure, then mount -o remount /"
    elif findmnt --verify >/dev/null 2>&1; then
      changed "fstab root options: relatime -> noatime,lazytime"
      run mount -o remount /
      changed "remounted / with the new options"
      need_reboot
      followup "findmnt -no OPTIONS /    # expect noatime,lazytime"
    else
      cp -a -- "/etc/fstab.bak-$STAMP" /etc/fstab
      warn "findmnt --verify failed on the edited /etc/fstab, restored the backup; disk section aborted"
      return 0
    fi
  fi
}

# --- boot --------------------------------------------------------------------
section_boot() {
  header "boot"
  local cfg=/boot/grub/grub.cfg
  if [ -d /sys/firmware/efi ]; then
    log "boot mode: UEFI"
  else
    log "boot mode: BIOS"
  fi
  if ! command -v grub-mkconfig >/dev/null 2>&1 || [ ! -f "$cfg" ] || [ ! -f /etc/default/grub ]; then
    note "GRUB not detected (grub-mkconfig, $cfg or /etc/default/grub missing); bootloader section skipped, regenerate your bootloader config by hand so it loads the microcode image"
    return 0
  fi
  log "bootloader: GRUB ($cfg)"

  if grep -qE '^GRUB_TIMEOUT=1$' /etc/default/grub; then
    log "unchanged: GRUB_TIMEOUT already 1"
  else
    sed_edit /etc/default/grub 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/'
    changed "GRUB_TIMEOUT=1"
  fi

  # 2.16 templates add bootnext entries (/etc/grub.d/31_efi_bootnext) that the installed 2.14 EFI core cannot run
  if [ -f /etc/grub.d/31_efi_bootnext ]; then
    if grep -qE '^GRUB_DISABLE_BOOTNEXT=' /etc/default/grub; then
      log "unchanged: GRUB_DISABLE_BOOTNEXT already set"
    else
      backup_file /etc/default/grub
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would append GRUB_DISABLE_BOOTNEXT=true to /etc/default/grub"
      else
        echo 'GRUB_DISABLE_BOOTNEXT=true' >>/etc/default/grub
      fi
      changed "GRUB_DISABLE_BOOTNEXT=true (no broken bootnext menu entries)"
    fi
  fi

  backup_file "$cfg"
  run grub-mkconfig -o "$cfg"
  changed "grub.cfg regenerated (also loads the CPU microcode image)"
  if [ "$DRY_RUN" -eq 0 ]; then
    if grep -q 'ucode' "$cfg"; then
      log "grub.cfg references a ucode image"
    else
      warn "grub.cfg has no ucode initrd; check that amd-ucode/intel-ucode is installed"
    fi
  fi
  need_reboot
}

# --- flatpak -----------------------------------------------------------------
section_flatpak() {
  header "flatpak"
  if ! command -v flatpak >/dev/null 2>&1; then
    log "flatpak not installed"
    return 0
  fi
  try flatpak update -y --noninteractive
  changed "system flatpaks updated"
  if { if [ "$EUID" -eq 0 ]; then sudo -u "$OWNER" -H flatpak list --user --app; else flatpak list --user --app; fi; } 2>/dev/null | grep -q .; then
    try sudo -u "$OWNER" -H flatpak update --user -y --noninteractive
    changed "user flatpaks updated"
  fi
}

# Last: what changed, reboot notice, follow-up commands for the owner.
section_summary() {
  header "summary"
  local item
  if [ "${#CHANGES[@]}" -gt 0 ]; then
    log "changes:"
    for item in "${CHANGES[@]}"; do log "  - $item"; done
  else
    log "no changes recorded in this run"
  fi
  if [ "${#NOTES[@]}" -gt 0 ]; then
    log "notes:"
    for item in "${NOTES[@]}"; do log "  - $item"; done
  fi
  if [ "${#FOLLOWUPS[@]}" -gt 0 ]; then
    log "follow-up commands for $OWNER:"
    for item in "${FOLLOWUPS[@]}"; do log "  $item"; done
  fi
  if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    log "REBOOT REQUIRED (kernel, microcode, fstab or boot configuration changed)"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry run: nothing was changed"
  fi
}

# --- main --------------------------------------------------------------------
main() {
  local s
  for s in "${SECTIONS[@]}"; do
    if [ -n "$ONLY" ] && [ "$s" != "$ONLY" ]; then
      continue
    fi
    "section_$s"
  done
}

main
