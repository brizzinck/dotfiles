#!/usr/bin/env bash
# Apply all root-level workstation changes (packages, /etc, services, disk, boot). Idempotent; safe to rerun.
#
#   sudo ./apply-system.sh                 run every section in order
#   sudo ./apply-system.sh --dry-run       print what each section would do, change nothing
#   sudo ./apply-system.sh --only cleanup  run a single section (several: --only users,mcp, always in the order below)
#
# Section order: cleanup -> upgrade -> install -> remove -> config -> services -> net -> greeter -> users -> mcp -> disk -> boot -> flatpak -> summary
#   (net = network exposure: firewall (ufw), LLMNR off, v2rayA web UI on loopback, see infrastructure/net;
#    also runnable alone: sudo ./apply-system.sh --only net)
#   (greeter = the login screen, see infrastructure/greetd; also runnable alone: sudo ./apply-system.sh --only greeter)
#   (users = managed child users, see infrastructure/users; also runnable alone: sudo ./apply-system.sh --only users)
#   (mcp = Telegram MCP service user setup, Chromium, whisper.cpp, see infrastructure/mcp; needs the users section for aimcp:
#    sudo ./apply-system.sh --only users,mcp)
# System config files live in infrastructure/<area>/ and are installed from there (see apply-memory.sh).
set -euo pipefail

ORIG_ARGS=("$@")
DRY_RUN=0
ONLY=""
STAMP="20261016"
SECTIONS=(cleanup upgrade install remove config services net greeter users mcp disk boot flatpak summary)

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
  for only_one in ${ONLY//,/ }; do
    case " ${SECTIONS[*]} " in
      *" $only_one "*) ;;
      *) echo "unknown section: $only_one (valid: ${SECTIONS[*]})" >&2; exit 2 ;;
    esac
  done
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
# exact package name only: pacman -Qq NAME also matches Provides (tlp-pd provides power-profiles-daemon)
pkg_installed_exact() { pacman -Qq 2>/dev/null | grep -qxF -- "$1"; }

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
  libqalculate chafa gifski kondo lostfiles termdown bandwhich lsof
  # C1: build dependencies of the local everforest-cursor-theme package (infrastructure/cursor); kept explicit so the orphan
  # step of the remove section does not drop them between runs (git, python and librsvg are installed anyway)
  xorg-xcursorgen librsvg
  # TLP profiles daemon: power-profiles-daemon D-Bus API backed by TLP (tlpctl); needs tlp, conflicts with power-profiles-daemon
  tlp-pd
  # phase 2 U5: Bitwarden/Vaultwarden client (rbw) with an fzf-menu front end; pinentry-qt (themed by qt6ct) needs kwindowsystem
  rbw kwindowsystem
  # phase 2 U6: official Bitwarden desktop app (SSH agent, Wayland). The CLI (bw) is the AUR package bitwarden-cli-bin:
  # the repo bitwarden-cli needs nodejs-lts-jod, which conflicts with the installed nodejs and aborts the transaction.
  # The desktop package hard-depends on org.freedesktop.secrets; with no provider installed pacman --noconfirm would pick one
  # at random (chipass came first). oo7 is the smallest provider (no deps, D-Bus activated, no PAM/keyring setup, not
  # gnome-keyring); the app itself keeps its vault keys in the kernel keyring, not in a Secret Service.
  oo7 bitwarden
  # G1: graphical login screen. greetd = login daemon (pulls greetd-agreety), quickshell = the greeter UI (Wayland, QML),
  # tuigreet = text fallback. The greeter runs in the Hyprland that is installed anyway (see section_greeter).
  greetd greetd-tuigreet quickshell
)
# AUR packages, built at run time as the owner (makepkg refuses root) and installed with pacman -U. A failure only warns.
# Keep in sync with the AUR section of install.sh. shellcheck-bin replaces the repo shellcheck (see swap_shellcheck).
# wlrctl + wl-kbptr: keyboard-driven pointer (SUPER+', SUPER+ALT+M); wlr-which-key: the SUPER+; leader menu. Their makedepends
# (meson, scdoc, wayland-protocols, rust) come from the repositories through aur_unmet_deps. wl-kbptr is NOT here: the AUR
# package needs opencv4 and Arch ships opencv 5, so it is a local PKGBUILD without opencv (install_local_kbptr).
# tmux-fingers: prefix f hints in tmux (Crystal, built from the pinned source tarball; makedepends crystal + shards come from extra);
# obs-cmd: OBS by keyboard over obs-websocket (leader o, hub rows; Rust, makedepends rust + git). OBS itself is never started.
# voxtype-bin: offline dictation (SUPER+ALT+D, hold F9; dictation.sh, user unit voxtype.service); downgrade: pacman cache
# rollback (hub row Update > Downgrade a package). Both guarded in the dotfiles: without them the keys say how to install.
AUR_PACKAGES=(bibata-cursor-theme-bin shellcheck-bin ccusage wayscrollshot-bin pacseek bitwarden-cli-bin wlrctl wlr-which-key tmux-fingers obs-cmd voxtype-bin downgrade)

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

# aur_import_pgp_keys SRCINFO PKG: makepkg verifies detached signatures with the OWNER's gpg keyring and fails on an unknown
# key ("unknown public key ..."). Import every fingerprint of `validpgpkeys` that is not there yet (keyserver.ubuntu.com, then
# keys.openpgp.org). A failed import only warns; the build then reports the signature error itself.
aur_import_pgp_keys() {
  local srcinfo="$1" pkg="$2" fp
  while read -r fp; do
    [ -n "$fp" ] || continue
    if run_as_owner gpg --list-keys "$fp" >/dev/null 2>&1; then
      log "unchanged: PGP key $fp ($pkg) is already in the keyring of $OWNER"
      continue
    fi
    if run_as_owner gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$fp" >/dev/null 2>&1 \
      || run_as_owner gpg --keyserver hkps://keys.openpgp.org --recv-keys "$fp" >/dev/null 2>&1; then
      changed "imported PGP key $fp for the AUR package $pkg into the keyring of $OWNER"
    else
      warn "could not import PGP key $fp for $pkg (keyservers unreachable?); the build may fail with an unknown public key"
    fi
  done < <(sed -nE 's/^[[:space:]]*validpgpkeys = ([0-9A-Fa-f]{16,40}).*/\1/p' "$srcinfo" | sort -u)
}

# aur_build_error LOG: the most telling line of a failed makepkg run (error/signature line), one line
aur_build_error() {
  local log_file="$1" line=""
  if [ -r "$log_file" ]; then
    line="$(grep -iE 'unknown public key|FAILED|error:|==> ERROR' "$log_file" | tail -n 1 | sed 's/^[[:space:]]*//')"
  fi
  printf '%s' "${line:-no makepkg error line captured}"
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
  aur_import_pgp_keys "$build_dir/srcinfo" "$pkg"
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
  if run_as_owner bash -c 'cd "$1/src" && PKGDEST="$1/out" makepkg --noconfirm 2>&1 | tee "$1/makepkg.log"; exit "${PIPESTATUS[0]}"' _ "$build_dir"; then
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
    warn "AUR build of $pkg FAILED ($(aur_build_error "$build_dir/makepkg.log")); continuing without it. Rerun: sudo $0 --only install"
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

# Local package from this repo (infrastructure/cursor): the Everforest pointer, hyprcursor SVG + XCursor of one artwork, colours from
# the palette (themes/generated/black/pointer.json). Built as the owner by infrastructure/cursor/build.sh (makepkg refuses
# root), installed with pacman -U; skipped when the installed theme carries the current build stamp (PKGBUILD + pointer.json).
# bibata-cursor-theme-bin stays installed as the fallback until the owner confirms the new pointer.
install_local_cursor() {
  local helper="$REPO/infrastructure/cursor/build.sh" out built
  if [ ! -x "$helper" ] || [ ! -r "$REPO/themes/generated/black/pointer.json" ]; then
    warn "infrastructure/cursor/build.sh or themes/generated/black/pointer.json missing, skipped the Everforest cursor"
    return 0
  fi
  if "$helper" --installed-current >/dev/null 2>&1; then
    log "unchanged: Everforest-Cursor is installed and up to date"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would build everforest-cursor-theme (infrastructure/cursor/PKGBUILD, git pinned by commit) as $OWNER with makepkg, then pacman -U it into /usr/share/icons/Everforest-Cursor"
    return 0
  fi
  if ! pacman -T git python librsvg xorg-xcursorgen >/dev/null; then
    try pacman -S --needed --noconfirm git python librsvg xorg-xcursorgen
  fi
  out="$(mktemp -d /tmp/everforest-cursor-pkg.XXXXXX)"
  chown "$OWNER": "$out"
  if built="$(run_as_owner "$helper" --build "$out")" && [ -n "$built" ]; then
    if pacman -U --noconfirm "$built"; then
      changed "installed everforest-cursor-theme (Everforest-Cursor; run ~/.local/bin/cursor-apply after logging in again, or it is used at the next Hyprland start)"
    else
      warn "built everforest-cursor-theme but pacman -U failed"
    fi
  else
    warn "building everforest-cursor-theme failed, Bibata stays the pointer"
  fi
  rm -rf -- "$out"
}

# Local package from this repo (infrastructure/aur/wl-kbptr): the AUR PKGBUILD with -Dopencv=disabled and no opencv dependency
# (the AUR one looks for opencv4.pc, Arch ships opencv 5; opencv is only for the unused `floating` mode). Built as the owner by
# infrastructure/aur/wl-kbptr/build.sh, installed with pacman -U; skipped when the installed pkgver-pkgrel is the PKGBUILD's.
install_local_kbptr() {
  local helper="$REPO/infrastructure/aur/wl-kbptr/build.sh" out built unmet=()
  if [ ! -x "$helper" ]; then
    warn "infrastructure/aur/wl-kbptr/build.sh missing, skipped wl-kbptr"
    return 0
  fi
  if "$helper" --installed-current >/dev/null 2>&1; then
    log "unchanged: wl-kbptr is installed and up to date"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would build wl-kbptr (infrastructure/aur/wl-kbptr/PKGBUILD, -Dopencv=disabled) as $OWNER with makepkg, then pacman -U it"
    return 0
  fi
  mapfile -t unmet < <(pacman -T meson wayland-protocols cairo wayland libxkbcommon pixman || true)
  if [ "${#unmet[@]}" -gt 0 ] && ! pacman -S --needed --asdeps --noconfirm -- "${unmet[@]}"; then
    warn "dependencies of wl-kbptr (${unmet[*]}) could not be installed, skipped wl-kbptr"
    return 0
  fi
  out="$(mktemp -d /tmp/wl-kbptr-pkg.XXXXXX)"
  chown "$OWNER": "$out"
  if built="$(run_as_owner "$helper" --build "$out")" && [ -n "$built" ]; then
    if pacman -U --noconfirm "$built"; then
      changed "installed wl-kbptr (local build without opencv)"
    else
      warn "built wl-kbptr but pacman -U failed"
    fi
  else
    warn "building wl-kbptr failed, continuing without it"
  fi
  rm -rf -- "$out"
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
  install_local_cursor
  install_local_kbptr

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

  # TLP drop-ins (61-battery-care.conf only sets STOP_CHARGE_THRESH_*, no overlap with 62-power.conf, which sets
  # platform profile, EPP and boost for all three tlp-pd profiles). TLP reads /etc/tlp.d only on a run, so it is
  # started again (applies the active profile) exactly when one of the two files changed.
  local tlp_changed=0 f
  for f in 61-battery-care.conf 62-power.conf; do
    cmp -s -- "$INFRA/tlp/$f" "/etc/tlp.d/$f" 2>/dev/null || tlp_changed=1
    install_file "$INFRA/tlp/$f" "/etc/tlp.d/$f"
  done
  if [ "$tlp_changed" -eq 1 ] && command -v tlp >/dev/null 2>&1; then
    try tlp start
    changed "tlp start (applied /etc/tlp.d/61-battery-care.conf and 62-power.conf to the active profile)"
  else
    log "tlp start not needed (/etc/tlp.d drop-ins unchanged)"
  fi

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
  # O1 UPD1: background download of pending pacman updates. Same method as `checkupdates -d` (private database copy, so no
  # partial-upgrade state); it NEVER installs. The install is `sysup`, started by the owner. AC power only (unit condition).
  install_file "$INFRA/pacman/dotfiles-predownload" /usr/local/bin/dotfiles-predownload 755
  install_file "$INFRA/systemd/dotfiles-predownload.service" /etc/systemd/system/dotfiles-predownload.service
  install_file "$INFRA/systemd/dotfiles-predownload.timer" /etc/systemd/system/dotfiles-predownload.timer
  run systemctl daemon-reload
  local u
  # tlp-pd.service (TLP Profiles Daemon) is D-Bus activated and sits next to tlp.service: it only runs "tlp <profile>"
  # for profile switches (tlpctl); performance -> *_ON_AC, balanced -> *_ON_BAT, power-saver -> *_ON_SAV of /etc/tlp.d/62-power.conf
  for u in fstrim.timer paccache.timer reflector.timer earlyoom.service tlp-pd.service; do
    # one unit at a time: a missing unit (for example after a failed install) must not cancel the others
    try systemctl enable --now "$u"
  done
  changed "enabled fstrim.timer paccache.timer reflector.timer earlyoom.service tlp-pd.service (per unit, failures are warnings)"
  try systemctl enable --now dotfiles-predownload.timer
  changed "enabled dotfiles-predownload.timer (downloads pending pacman updates into the cache, installs nothing)"
  if pkg_installed_exact power-profiles-daemon; then
    warn "power-profiles-daemon is installed and owns the same D-Bus names as tlp-pd (the packages conflict); remove it"
  fi

  # docker reads daemon.json only at start and a restart now would stop containers without a restart policy: no restart here
  if systemctl is-active --quiet docker.service && docker_config_stale; then
    note "restart docker or reboot to apply daemon.json (BuildKit GC cap); the reboot at the end of this run applies it"
    followup "after reboot: docker info --format '{{json .BuilderGC}}' 2>/dev/null; docker start pgadmin   # restart=no container"
  else
    log "docker restart not needed (daemon.json already applied or docker is not running)"
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
  followup "systemctl list-timers fstrim.timer paccache.timer reflector.timer dotfiles-predownload.timer"
  followup "cat /var/lib/dotfiles-predownload/state    # epoch, package count, ok (after the first background download); sysup status"
  followup "tlpctl list; tlpctl get    # TLP Profiles Daemon (powerprofilesctl-compatible D-Bus API, no powerprofilesctl binary); busctl introspect org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles"
}

# --- net ---------------------------------------------------------------------
# Network exposure (infrastructure/net): nothing listens on the LAN by intent, and a default-deny firewall covers what
# does by accident. Three independent parts, all idempotent; a service is reloaded or restarted only when its drop-in changed.
#   1. systemd-resolved: LLMNR off (/etc/systemd/resolved.conf.d/10-no-llmnr.conf)
#   2. v2rayA: web UI on 127.0.0.1:2017 (drop-in with V2RAYA_ADDRESS), restarted only when it runs
#   3. ufw: deny incoming, allow outgoing, IPv6 on, logging low, the rules of infrastructure/net/ufw-rules.conf
# ufw (not nftables directly): it is installed, the rules live in /etc/ufw and are managed with one CLI, and with
# MANAGE_BUILTINS=no it only adds its own chains next to Docker's iptables-nft rules. An /etc/nftables.conf that starts
# with "flush ruleset" would delete Docker's NAT and forward tables every time nftables.service restarts.
NET_SRC="$INFRA/net"
NET_MARKER=/etc/ufw/.dotfiles-net

# etc_default_set FILE KEY VALUE: make "KEY=VALUE" the line of KEY (append when missing); no-op when already so.
etc_default_set() {
  local f="$1" k="$2" v="$3"
  if grep -qxF -- "$k=$v" "$f" 2>/dev/null; then
    log "unchanged: $f $k=$v"
  elif grep -q "^$k=" "$f" 2>/dev/null; then
    sed_edit "$f" "s|^$k=.*|$k=$v|"
    changed "$f: $k=$v"
  else
    backup_file "$f"
    run sh -c "printf '%s\n' '$k=$v' >> '$f'"
    changed "$f: $k=$v (appended)"
  fi
}

net_firewall() {
  local line out
  if ! command -v ufw >/dev/null 2>&1; then
    warn "net: ufw is not installed (pacman -S ufw), the firewall part was skipped"
    return 0
  fi
  # a. sysctl file ufw applies at every start (stock file minus the strict rp_filter lines, see the file header)
  install_file "$NET_SRC/ufw-sysctl.conf" /etc/ufw/dotfiles-sysctl.conf
  etc_default_set /etc/default/ufw IPT_SYSCTL /etc/ufw/dotfiles-sysctl.conf
  etc_default_set /etc/default/ufw IPV6 yes
  # b. policy: deny incoming, allow outgoing, deny routed (Docker's own FORWARD rules sit next to it and keep container traffic working)
  if grep -qx 'DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw 2>/dev/null; then
    log "unchanged: ufw default incoming = deny"
  else
    run ufw default deny incoming
    changed "ufw default deny incoming"
  fi
  if grep -qx 'DEFAULT_OUTPUT_POLICY="ACCEPT"' /etc/default/ufw 2>/dev/null; then
    log "unchanged: ufw default outgoing = allow"
  else
    run ufw default allow outgoing
    changed "ufw default allow outgoing"
  fi
  if grep -qx 'DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw 2>/dev/null; then
    log "unchanged: ufw default routed = deny"
  else
    run ufw default deny routed
    changed "ufw default deny routed"
  fi
  if grep -qx 'LOGLEVEL=low' /etc/ufw/ufw.conf 2>/dev/null; then
    log "unchanged: ufw logging low"
  else
    run ufw logging low
    changed "ufw logging low"
  fi
  # c. the rules of the repo list (ufw skips a rule that already exists)
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    # shellcheck disable=SC2086 # the line is ufw's argument list by design
    run ufw $line
    changed "ufw $line"
  done <"$NET_SRC/ufw-rules.conf"
  # d. rules somebody added by hand: never silently kept or removed
  out="$("$NET_SRC/exposure-check.sh" stale-rules 2>/dev/null)"
  if [ -n "$out" ]; then
    warn "net: ufw has allow rules that infrastructure/net/ufw-rules.conf does not list; they open ports as soon as something listens there: $(printf '%s' "$out" | sed 's/ -j ACCEPT$//; s/^[^:]*: -A ufw6\?-user-[a-z]* //' | sort -u | paste -sd';' -)"
    followup "stale ufw rules (decide, then: sudo ufw status numbered; sudo ufw delete N  -- or add the line to infrastructure/net/ufw-rules.conf): see the warning above"
  fi
  # e. switch it on (the rules above are in place first, so there is no open window)
  if grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null && systemctl is-active --quiet ufw.service; then
    log "unchanged: ufw is enabled and active"
  else
    run ufw --force enable
    changed "ufw enabled: default deny incoming, loopback and established/related allowed, outgoing allowed"
  fi
  try systemctl enable ufw.service
  run touch "$NET_MARKER"
  followup "sudo ufw status verbose    # Status: active, Default: deny (incoming), allow (outgoing), deny (routed)"
  followup "docker run --rm busybox wget -qO- -T 5 https://example.com | head -c 60    # a container still reaches the internet through the firewall"
}

section_net() {
  header "net"
  local resolved_changed=0 v2_changed=0
  # 1. LLMNR off. mDNS stays as it is.
  cmp -s -- "$NET_SRC/10-no-llmnr.conf" /etc/systemd/resolved.conf.d/10-no-llmnr.conf 2>/dev/null || resolved_changed=1
  install_file "$NET_SRC/10-no-llmnr.conf" /etc/systemd/resolved.conf.d/10-no-llmnr.conf
  if [ "$resolved_changed" -eq 1 ]; then
    try systemctl try-reload-or-restart systemd-resolved.service
    changed "systemd-resolved reloaded or restarted (LLMNR=no)"
  else
    log "systemd-resolved: LLMNR drop-in unchanged, no reload"
  fi
  # 2. v2rayA web UI on loopback
  if [ -e /usr/lib/systemd/system/v2raya.service ] || [ -e /etc/systemd/system/v2raya.service ]; then
    cmp -s -- "$NET_SRC/v2raya-loopback.conf" /etc/systemd/system/v2raya.service.d/10-loopback.conf 2>/dev/null || v2_changed=1
    install_file "$NET_SRC/v2raya-loopback.conf" /etc/systemd/system/v2raya.service.d/10-loopback.conf
    if [ "$v2_changed" -eq 1 ]; then
      run systemctl daemon-reload
      if systemctl is-active --quiet v2raya.service; then
        # a restart drops the running proxy for a moment; v2rayA restores its core itself
        try systemctl restart v2raya.service
        changed "v2raya restarted (web UI now on 127.0.0.1:2017)"
      else
        log "v2raya is not running: no restart needed, it starts with the new address"
      fi
    else
      log "v2raya: loopback drop-in unchanged, no restart"
    fi
  else
    log "v2raya is not installed: nothing to bind"
  fi
  # 3. firewall
  net_firewall
  followup "ss -ltnH | awk '{print \$4}' | grep -v '^127\\.'   # nothing but your allowlisted ports (doctor net-exposure lists them)"
  followup "systemctl --user restart camoufox-gateway    # applies the 127.0.0.1 bind of ~/job/youtube/.../camoufox_gateway.py (interrupts running Flow jobs)"
}

# --- greeter -----------------------------------------------------------------
# Login screen (stage G1): greetd + a Quickshell greeter in a minimal Hyprland, tuigreet as the fallback. Sources live in
# infrastructure/greetd/ (copied, not symlinked). The switch is "enable greetd, disable getty@tty1, reboot":
# greetd.service has Conflicts=getty@tty1.service, so it is NEVER started or restarted from here (that would stop the
# getty the running tty1 login belongs to). Everything below is idempotent; rerun it after editing the greeter.
GREETD_SRC="$INFRA/greetd"
GREETER_BANNER=0

greeter_banner() {
  cat <<'BANNER'

################################################################################
#  LOGIN SCREEN INSTALLED, NOT STARTED.  REBOOT TO SWITCH TO IT.
#
#  greetd is enabled for the next boot and getty@tty1 is disabled. Nothing was
#  started now (greetd conflicts with getty@tty1, which your session runs on).
#
#  After the reboot: log in with your password (the "main" avatar), or pick
#  "Other user..." and type a name. The graphical greeter falls back to a text
#  login (tuigreet) by itself when it cannot start.
#
#  ROLLBACK from TTY2 (Ctrl+Alt+F2, log in there):
#      sudo systemctl disable greetd && sudo systemctl enable getty@tty1 && sudo reboot
#  EMERGENCY (no VT reachable): in GRUB press `e` on the entry and append
#      systemd.mask=greetd.service
#  to the linux line, then Ctrl+X; log in on a text tty and roll back as above.
#  Text greeter only: see the comment at the top of /etc/greetd/config.toml.
################################################################################

BANNER
}

section_greeter() {
  header "greeter"
  local p missing=() f dest name tmp

  # packages: also checked here so that --only greeter works without the install section
  for p in greetd greetd-tuigreet quickshell; do
    pkg_installed "$p" || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "greeter packages missing: ${missing[*]}"
    try pacman -S --needed --noconfirm "${missing[@]}"
    if [ "$DRY_RUN" -eq 0 ]; then
      for p in greetd quickshell; do
        if ! pkg_installed "$p"; then
          warn "greeter: $p is not installed (pacman failed); the login screen was NOT set up and nothing was switched"
          return 0
        fi
      done
    fi
  fi
  if [ ! -d "$GREETD_SRC" ]; then
    warn "greeter: $GREETD_SRC is missing, nothing to install"
    return 0
  fi
  if [ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]; then
    warn "default.target is not graphical.target: greetd (display-manager.service) would not start at boot"
  fi

  # greetd's sysusers entry (user greeter, group video) comes with the package; create it if the hook did not run
  if ! getent passwd greeter >/dev/null; then
    try systemd-sysusers
  fi

  # PAM service of the greetd sessions first: config.toml names it (service = "greetd-login"). It is the package's
  # /etc/pam.d/greetd without pam_securetty, which fails for root (greetd sets no PAM_TTY before authenticating)
  install_file "$GREETD_SRC/pam/greetd-login" /etc/pam.d/greetd-login
  # configuration, greeter UI and helper scripts
  install_file "$GREETD_SRC/config.toml" /etc/greetd/config.toml
  install_file "$GREETD_SRC/config-test.toml" /etc/greetd/config-test.toml
  install_file "$GREETD_SRC/tuigreet.toml" /etc/greetd/tuigreet.toml
  install_file "$GREETD_SRC/hyprland.lua" /etc/greetd/hyprland.lua
  install_file "$REPO/.config/hypr/monitors.lua" /etc/greetd/monitors.lua    # same monitor rules as the session
  install_file "$GREETD_SRC/greeter-session" /usr/local/lib/greeter/greeter-session 755
  install_file "$GREETD_SRC/run-qs" /usr/local/lib/greeter/run-qs 755
  install_file "$GREETD_SRC/hypr-login" /usr/local/bin/hypr-login 755
  install_file "$GREETD_SRC/shell-login" /usr/local/bin/shell-login 755     # the greeter's Shell session (a console login shell)
  install_file "$GREETD_SRC/tmpfiles.conf" /etc/tmpfiles.d/greeter.conf
  # Theme.qml in the repo is a symlink to themes/generated/black/greeter-palette.qml (install follows it)
  for f in "$GREETD_SRC"/greeter/*.qml; do
    install_file "$f" "/etc/greetd/greeter/$(basename "$f")"
  done
  # users.json keeps @OWNER@ in the repo (user-agnostic); the installed copy names this machine's owner
  tmp="$(mktemp)"
  sed "s|@OWNER@|$OWNER|g" "$GREETD_SRC/greeter/users.json" >"$tmp"
  install_file "$tmp" /etc/greetd/greeter/users.json
  rm -f -- "$tmp"
  # drop UI files that no longer exist in the repo (renamed or removed files must not linger and shadow new ones)
  if [ -d /etc/greetd/greeter ]; then
    for dest in /etc/greetd/greeter/*; do
      [ -e "$dest" ] || continue
      name="$(basename "$dest")"
      if [ ! -e "$GREETD_SRC/greeter/$name" ]; then
        run rm -f -- "$dest"
        changed "removed stale /etc/greetd/greeter/$name"
      fi
    done
  fi
  run systemd-tmpfiles --create /etc/tmpfiles.d/greeter.conf

  # the greeter runs as user "greeter": everything under /etc/greetd must be world-readable
  run chmod -R a+rX /etc/greetd

  # the switch: NEVER --now, start or restart (see the comment above)
  if [ "$DRY_RUN" -eq 0 ] && systemctl is-enabled --quiet greetd.service 2>/dev/null \
    && ! systemctl is-enabled --quiet getty@tty1.service 2>/dev/null; then
    log "unchanged: greetd.service is enabled and getty@tty1.service is disabled already"
  else
    run systemctl enable greetd.service        # Alias=display-manager.service, pulled in by graphical.target at the next boot
    run systemctl disable getty@tty1.service   # does not stop the running one; TTY2..6 (autovt@) keep working
    changed "greetd.service enabled, getty@tty1.service disabled (effective at the next boot, nothing started now)"
    need_reboot
  fi
  GREETER_BANNER=1
  followup "reboot to switch to the login screen; rollback from TTY2: sudo systemctl disable greetd && sudo systemctl enable getty@tty1 && sudo reboot"
  followup "emergency (no VT): GRUB entry, press e, append systemd.mask=greetd.service to the linux line, Ctrl+X"
  followup "optional test before the reboot, on VT3 (dry-run session; the Shell session is real; also try root under Other user...): sudo greetd --config /etc/greetd/config-test.toml (Ctrl+Alt+F1 returns, Ctrl+C stops it)"
  followup "after the reboot: ./doctor.sh --fails; loginctl show-session \$XDG_SESSION_ID -p Service -p Type    # Service=greetd, Type=wayland"
}

# --- users -------------------------------------------------------------------
# Managed child users (stage U7): td, yc and later service users such as aimcp, all listed in infrastructure/users/managed.tsv
# (the registry also read by the `usr` command and doctor.sh). What this section sets up, every step idempotent:
#   * the managed users get NO access to the owner's home: their ACL entries on it (access + default) are removed;
#   * the owner keeps full access to the managed homes (u:OWNER:rwx plus a default ACL);
#   * passwordless "become" for the owner, only for the listed users and never root: a sudoers drop-in (sudo -u USER ...)
#     and a polkit rule (machinectl shell USER@); users flagged nobecome (aimcp) get neither;
#   * /srv/dotfiles (published copy of ~/dotfiles, no secrets) and /srv/nvim-shared (nvim plugins + Mason, read-only for the
#     managed users), both owned by the owner so the commit hook can publish without a password;
#   * the first publish, the profile links (run as each managed user) and the shared nvim install (background).
# Passwords, shells and groups (wheel, docker) of existing users are never touched; no linger for interactive users.
# Rollback: sudo infrastructure/users/rollback.sh (it also prints what it did).
USERS_DIR="$INFRA/users"
USERS_STATE=/var/lib/usr-managed
USERS_SUDOERS=/etc/sudoers.d/50-usr-managed
USERS_POLKIT=/etc/polkit-1/rules.d/50-usr-managed.rules
USERS_SRV_DOTFILES=/srv/dotfiles
USERS_SRV_NVIM=/srv/nvim-shared

# stdout: the sudoers drop-in / polkit rule rendered from managed.tsv (users with the `become` capability)
users_render_sudoers() {
  local list
  list="$(managed_users become | paste -sd, - | sed 's/,/, /g')"
  sed -e "s|@OWNER@|$OWNER|g" -e "s|@MANAGED@|$list|" "$USERS_DIR/sudoers/50-usr-managed.in"
}
users_render_polkit() {
  local list
  list="$(managed_users become | sed 's/.*/"&"/' | paste -sd, - | sed 's/,/, /g')"
  sed -e "s|@OWNER@|$OWNER|g" -e "s|@MANAGED_JS@|$list|" "$USERS_DIR/polkit/50-usr-managed.rules.in"
}
users_check_sudoers() { visudo -c -f "$1" >/dev/null 2>&1; }
users_check_polkit() {
  command -v node >/dev/null 2>&1 || return 0   # no node: the rule is plain ES5, install it unchecked
  local t rc
  t="$(mktemp --suffix=.js)"
  cp -- "$1" "$t"
  node --check "$t" >/dev/null 2>&1
  rc=$?
  rm -f -- "$t"
  return "$rc"
}
# users_install_rendered RENDER_FN DEST MODE CHECK_FN: render, validate, then install (or report unchanged)
users_install_rendered() {
  local fn="$1" dest="$2" mode="$3" check="$4" tmp
  tmp="$(mktemp)"
  "$fn" >"$tmp"
  if ! "$check" "$tmp"; then
    warn "users: the rendered $(basename "$dest") failed its syntax check; NOT installed (the old file stays)"
    rm -f -- "$tmp"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "rendered $dest (mode $mode):"
    sed 's/^/    | /' "$tmp"
  fi
  install_file "$tmp" "$dest" "$mode"
  rm -f -- "$tmp"
}

# users_acl_remove USER: drop USER's access and default ACL entries from the owner's home tree (-xdev, no symlinks)
users_acl_remove() {
  local u="$1" n_entries n_total top stamp saved
  [ -d "$OWNER_HOME" ] || return 0
  # the top two levels are read back exactly (fast); reading every ACL of the whole tree takes minutes
  top="$(find "$OWNER_HOME" -xdev -maxdepth 2 ! -type l -print0 2>/dev/null | xargs -0 -r getfacl -p -s 2>/dev/null |
    awk -v u="$u" '/^# file: / { f = substr($0, 9); next } $0 ~ "^(default:)?user:" u ":" { sub(/\t.*/, ""); print f "\t" $0 }')"
  n_entries="$(printf '%s' "$top" | grep -c . || true)"
  if [ "$n_entries" -eq 0 ] && [ "$DRY_RUN" -eq 1 ]; then
    log "unchanged: $u has no ACL entry in the top two levels of $OWNER_HOME"
    return 0
  fi
  n_total="$(find "$OWNER_HOME" -xdev ! -type l 2>/dev/null | wc -l)"
  log "ACL entries of $u on $OWNER_HOME that go (each of the $n_total files and directories below it is visited):"
  if [ "$n_entries" -gt 0 ]; then
    log "  top two levels: $n_entries entries, by kind:"
    printf '%s\n' "$top" | cut -f2 | sort | uniq -c | sort -rn | sed 's/^ *\([0-9]*\) \(.*\)/    \1 x \2/'
    log "  the home directory itself and its direct children (first 30):"
    printf '%s\n' "$top" | awk -F'\t' -v h="$OWNER_HOME" '$1 == h || index($1, h "/") == 1 { rest = substr($1, length(h) + 2); if (rest !~ /\//) print "    " $1 "   " $2 }' | sed -n '1,30p'
  fi
  log "  removed: user:$u:*          (access entry, files and directories)"
  log "  removed: default:user:$u:*  (default entry, directories: new files no longer inherit it)"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] getfacl of the top two levels is saved to $USERS_STATE/acl-before-$u-<time>.txt (rollback reference)"
    log "[dry-run] find $OWNER_HOME -xdev ! -type l -type d -exec setfacl -x u:$u,d:u:$u {} +"
    log "[dry-run] find $OWNER_HOME -xdev ! -type l ! -type d -exec setfacl -x u:$u {} +"
    changed "would remove every ACL entry of $u from $OWNER_HOME"
    return 0
  fi
  install -d -m 700 "$USERS_STATE"
  stamp="$(date +%Y%m%d-%H%M%S)"
  saved="$USERS_STATE/acl-before-$u-$stamp.txt"
  find "$OWNER_HOME" -xdev -maxdepth 2 ! -type l -print0 2>/dev/null | xargs -0 -r getfacl -p -s >"$saved" 2>/dev/null || true
  find "$OWNER_HOME" -xdev ! -type l -type d -exec setfacl -x "u:$u,d:u:$u" {} + 2>/dev/null ||
    warn "users: some directories under $OWNER_HOME could not be changed (setfacl -x u:$u)"
  find "$OWNER_HOME" -xdev ! -type l ! -type d -exec setfacl -x "u:$u" {} + 2>/dev/null ||
    warn "users: some files under $OWNER_HOME could not be changed (setfacl -x u:$u)"
  changed "removed every ACL entry of $u from $OWNER_HOME (before-state of the top levels: $saved)"
}

# users_home_acl USER: the owner gets u:OWNER:rwx and a default ACL on the managed home (once; later files inherit it)
users_home_acl() {
  local u="$1" h
  h="$(getent passwd "$u" | cut -d: -f6)"
  [ -n "$h" ] && [ -d "$h" ] || { log "skip: $u has no home directory yet"; return 0; }
  if getfacl -p "$h" 2>/dev/null | grep -q "^user:$OWNER:rwx" && getfacl -p "$h" 2>/dev/null | grep -q "^default:user:$OWNER:rwx"; then
    log "unchanged: $h already carries u:$OWNER:rwx and the default ACL"
    return 0
  fi
  # directories get mask rwx (the owner can traverse and write); 0600 files keep an empty mask: secrets stay owner-only on
  # the browsing path and are reached with `usr exec` / `usr edit`. .ssh and .gnupg are never touched.
  run setfacl -m "u:$OWNER:rwx" "$h"
  run setfacl -d -m "u::rwx,u:$u:rwx,u:$OWNER:rwx,g::---,m::rwx,o::---" "$h"
  run find "$h" -xdev '(' -path "$h/.ssh" -o -path "$h/.gnupg" ')' -prune -o -type d -exec setfacl -m "u:$OWNER:rwx,d:u:$OWNER:rwx,d:u:$u:rwx" '{}' +
  run find "$h" -xdev '(' -path "$h/.ssh" -o -path "$h/.gnupg" ')' -prune -o ! -type d ! -type l -exec setfacl -n -m "u:$OWNER:rwX" '{}' +
  run install -d -m 700 "$USERS_STATE"
  run touch "$USERS_STATE/home-acl-added-$u"   # rollback.sh removes the owner's ACL again from homes that had none
  changed "$h: ACL u:$OWNER:rwx + default ACL (existing tree normalised once, .ssh/.gnupg skipped)"
}

section_users() {
  header "users"
  local lib="$USERS_DIR/lib.sh" u problems usr_cmd grp nvim_mode has_profile_user
  if [ ! -r "$lib" ]; then
    warn "users: $lib is missing, nothing to do"
    return 0
  fi
  # shellcheck source=infrastructure/users/lib.sh
  source "$lib"
  problems="$(managed_validate "$OWNER")"
  if [ -n "$problems" ]; then
    warn "users: infrastructure/users/managed.tsv is invalid, the section was NOT run:"
    printf '  %s\n' "$problems" >&2
    return 0
  fi
  usr_cmd="$REPO/.local/bin/usr"
  grp="$(id -gn "$OWNER")"
  log "owner: $OWNER; managed users: $(managed_users | paste -sd' ' -)"

  # 1. service accounts that do not exist yet (td and yc are never created, re-shelled or re-grouped)
  for u in $(managed_users create); do
    if getent passwd "$u" >/dev/null; then
      log "unchanged: account $u exists"
    else
      run useradd -m -U -s /usr/bin/nologin -K HOME_MODE=0700 "$u"
      run passwd -l "$u"
      changed "created the service account $u (shell /usr/bin/nologin, password locked, home 0700)"
    fi
  done

  # 2. no managed user reaches the owner's home
  for u in $(managed_users); do
    getent passwd "$u" >/dev/null || { log "skip: account $u does not exist"; continue; }
    users_acl_remove "$u"
  done

  # 3. the owner reaches every managed home (unless flagged noacl)
  for u in $(managed_users acl); do
    getent passwd "$u" >/dev/null || continue
    users_home_acl "$u"
  done

  # 4. published directories, owned by the owner: the commit hook writes them without a password
  for u in "$USERS_SRV_DOTFILES" "$USERS_SRV_NVIM"; do
    if [ -d "$u" ] && [ "$(stat -c %U "$u")" = "$OWNER" ] && [ "$(stat -c %a "$u")" = 755 ]; then
      log "unchanged: $u ($OWNER:$grp 755)"
    else
      run install -d -o "$OWNER" -g "$grp" -m 755 "$u"
      changed "$u created/fixed ($OWNER:$grp 755, read-only for the managed users)"
    fi
  done

  # 5. passwordless become for the owner: sudoers + polkit, validated before they are installed
  if [ -n "$(managed_users become)" ]; then
    users_install_rendered users_render_sudoers "$USERS_SUDOERS" 440 users_check_sudoers || true
    users_install_rendered users_render_polkit "$USERS_POLKIT" 644 users_check_polkit || true
  else
    for u in "$USERS_SUDOERS" "$USERS_POLKIT"; do
      if [ -e "$u" ]; then
        run rm -f -- "$u"
        changed "removed $u (no managed user allows a passwordless become)"
      fi
    done
  fi

  # 6. no linger and no user services for the interactive users: their terminal windows own their processes
  for u in $(managed_users interactive); do
    if [ -e "/var/lib/systemd/linger/$u" ]; then
      run loginctl disable-linger "$u"
      changed "linger disabled for $u (the terminal window owns its processes)"
    fi
  done

  # 7. user layer, run as the owner / as each managed user: publish ~/dotfiles, link the profiles, install nvim once
  has_profile_user=0
  for u in $(managed_users profile); do
    if getent passwd "$u" >/dev/null; then has_profile_user=1; fi
  done
  if [ "$has_profile_user" -eq 0 ]; then
    log "skip: no existing managed user has a dotfiles profile (rerun this section after adding one)"
  elif [ ! -x "$usr_cmd" ]; then
    warn "users: $usr_cmd is missing; publish, profile links and the shared nvim install were skipped"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] sudo -u $OWNER -H $usr_cmd sync --quiet    # publish the committed ~/dotfiles to $USERS_SRV_DOTFILES"
    for u in $(managed_users profile); do
      log "[dry-run] profile links of $u (read-only preview, nothing is written):"
      "$usr_cmd" link "$u" --dry-run 2>&1 | sed 's/^/    /' || true
    done
    log "[dry-run] sudo -u $OWNER -H $usr_cmd nvim-sync --background    # nvim plugins + Mason into $USERS_SRV_NVIM"
  else
    run_as_owner "$usr_cmd" sync --quiet || warn "users: usr sync failed (run it as $OWNER and read its output)"
    changed "published ~/dotfiles (committed state, no secrets) to $USERS_SRV_DOTFILES"
    for u in $(managed_users profile); do
      getent passwd "$u" >/dev/null || continue
      if sudo -u "$u" -H "$USERS_SRV_DOTFILES/.local/bin/usr" _link; then
        changed "linked the profile $(managed_field "$u" profile) into /home/$u (replaced links/files are in ~/.local/state/usr/backup-*)"
      else
        warn "users: linking the profile of $u failed (run: usr link $u)"
      fi
    done
    nvim_mode="${USERS_NVIM_SYNC:-background}"
    case "$nvim_mode" in
      skip) log "skip: shared nvim install (USERS_NVIM_SYNC=skip); run: usr nvim-sync" ;;
      foreground) run_as_owner "$usr_cmd" nvim-sync || warn "users: usr nvim-sync failed" ;;
      *)
        run_as_owner "$usr_cmd" nvim-sync --background || warn "users: usr nvim-sync could not be started"
        log "shared nvim install runs in the background: tail -f ~/.local/state/usr/nvim-sync.log"
        ;;
    esac
  fi

  followup "managed users: usr list | usr term td | SUPER+SHIFT+T (picker); checks: ./doctor.sh | grep users-"
  followup "rollback of the users section: sudo $USERS_DIR/rollback.sh"
}

# --- mcp ---------------------------------------------------------------------
# Root part of the MCP stage (M1); the gateway itself is a user service (mcp-install, no root). What this section sets up, every
# step idempotent and pinned (infrastructure/mcp/telegram/pins.env):
#   * packages: chromium (the clean automation browser of the chrome-devtools gateway server; a flatpak Chrome cannot be
#     driven over the CDP pipe) and whisper-cpp (whisper-server for voice messages);
#   * retires mcp-hub: removes /srv/mcphub (the last servers.json is kept in ~/.local/share/workstation-overhaul/mcphub-backup);
#   * /srv/models/ggml-small.bin: the Whisper model Voxtype dictation uses (copied from the owner's home when its sha256
#     matches, else downloaded and checked), shared through a readable path because aimcp cannot read /home;
#   * /opt/telegram-mcp: chigwell/telegram-mcp at the pinned commit + a hash-pinned venv (root-owned, world-readable);
#   * the service user aimcp comes from the users section (managed.tsv row: service, noacl, nobecome, create), so run
#     `--only users,mcp`; the owner reaches it only with a sudo password;
#   * units: telegram-mcp.service (user aimcp, 127.0.0.1:8765, LoadCredentialEncrypted= from /etc/credstore.encrypted, sandboxed;
#     only starts once mcp-telegram-setup stored the credentials), telegram-whisper-proxy.socket (127.0.0.1:8766) which starts
#     telegram-whisper.service (whisper.cpp server) on demand and stops it after 5 idle minutes;
#   * /usr/local/lib/telegram-mcp/{run,serve.py,creds-install,login.py,send.conf}: the wrapper, the fail-closed entry point (also
#     the owner-confirmed POST /x-send route), the root helper that mcp-telegram-setup calls through sudo, the QR login / chat
#     lister and the drop-in text for the optional send credentials.
# Nothing is logged in to Telegram here: the owner runs `mcp-telegram-setup` (QR + sudo password + master password).
MCP_DIR="$INFRA/mcp/telegram"
TG_OPT=/opt/telegram-mcp
TG_LIB=/usr/local/lib/telegram-mcp
MODELS_DIR=/srv/models
CREDSTORE=/etc/credstore.encrypted

mcp_retire_hub() {
  if [ -d /srv/mcphub ]; then
    run rm -rf -- /srv/mcphub
    changed "removed /srv/mcphub (mcp-hub is retired; backup of servers.json: ~/.local/share/workstation-overhaul/mcphub-backup)"
  else
    log "unchanged: /srv/mcphub is already gone"
  fi
  if pgrep -f 'mcp-hub --port' >/dev/null 2>&1; then
    run pkill -f 'mcp-hub --port'
    changed "stopped a running mcp-hub"
  fi
}

mcp_whisper_model() {
  local f want src part got
  # shellcheck source=/dev/null
  . "$MCP_DIR/pins.env"
  f="$MODELS_DIR/$WHISPER_MODEL_FILE" want="$WHISPER_MODEL_SHA256"
  if [ -s "$f" ] && [ -e "$MODELS_DIR/.verified-$want" ]; then
    log "unchanged: $f (sha256 verified before)"
    return 0
  fi
  if [ -s "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ]; then
    run touch "$MODELS_DIR/.verified-$want"
    log "unchanged: $f matches the pinned sha256"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would put $WHISPER_MODEL_FILE (sha256 $want) into $MODELS_DIR: copy from $OWNER_HOME/.local/share/voxtype/models if it matches, else download $WHISPER_MODEL_URL"
    return 0
  fi
  install -d -m 755 "$MODELS_DIR"
  src="$OWNER_HOME/.local/share/voxtype/models/$WHISPER_MODEL_FILE"
  part="$f.part"
  if [ -s "$src" ] && [ "$(sha256sum "$src" | cut -d' ' -f1)" = "$want" ]; then
    cp -- "$src" "$part"
    log "copied the Voxtype model from $src"
  else
    log "downloading $WHISPER_MODEL_FILE (about 466 MB, once)"
    if ! curl -fL --retry 3 -C - -o "$part" "$WHISPER_MODEL_URL"; then
      warn "mcp: downloading the Whisper model failed; voice messages cannot be transcribed until: sudo $0 --only mcp"
      return 0
    fi
  fi
  got="$(sha256sum "$part" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    warn "mcp: the Whisper model has the wrong sha256 ($got, expected $want); NOT installed"
    rm -f -- "$part"
    return 0
  fi
  chmod 644 "$part"
  mv -f -- "$part" "$f"
  touch "$MODELS_DIR/.verified-$want"
  changed "installed $f (sha256 verified, shared with aimcp)"
}

mcp_telegram_source() {
  local commit="$TELEGRAM_MCP_COMMIT" head stamp want_stamp was_active=0
  if [ -d "$TG_OPT/src/.git" ] && [ "$(git -C "$TG_OPT/src" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
    log "unchanged: $TG_OPT/src is at $commit"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would fetch $TELEGRAM_MCP_REPO at commit $commit into $TG_OPT/src (shallow, verified with git rev-parse)"
  else
    install -d -m 755 "$TG_OPT"
    rm -rf -- "$TG_OPT/src"
    if git init -q "$TG_OPT/src" && git -C "$TG_OPT/src" fetch -q --depth 1 "$TELEGRAM_MCP_REPO" "$commit" \
      && git -C "$TG_OPT/src" -c advice.detachedHead=false checkout -q FETCH_HEAD; then
      head="$(git -C "$TG_OPT/src" rev-parse HEAD)"
      if [ "$head" != "$commit" ]; then
        warn "mcp: fetched commit $head is not the pinned $commit; removed"
        rm -rf -- "$TG_OPT/src"
        return 1
      fi
      chown -R root:root "$TG_OPT/src"
      chmod -R go-w,a+rX "$TG_OPT/src"
      changed "telegram-mcp source at the pinned commit $commit in $TG_OPT/src"
    else
      warn "mcp: could not fetch telegram-mcp ($TELEGRAM_MCP_REPO @ $commit); the service cannot be set up"
      rm -rf -- "$TG_OPT/src"
      return 1
    fi
  fi
  want_stamp="$(cat "$MCP_DIR/requirements.txt" | sha256sum | cut -d' ' -f1)-$commit-$(python3 -c 'import sys; print(sys.version_info[:2])')"
  stamp="$(cat "$TG_OPT/venv/.stamp" 2>/dev/null || true)"
  if [ -x "$TG_OPT/venv/bin/python" ] && [ "$stamp" = "$want_stamp" ]; then
    log "unchanged: $TG_OPT/venv is current"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would build $TG_OPT/venv with pip install --require-hashes --no-deps -r infrastructure/mcp/telegram/requirements.txt"
    return 0
  fi
  systemctl is-active --quiet telegram-mcp.service && was_active=1
  [ "$was_active" -eq 1 ] && systemctl stop telegram-mcp.service
  rm -rf -- "$TG_OPT/venv"
  if python3 -m venv "$TG_OPT/venv" \
    && "$TG_OPT/venv/bin/python" -m pip install --quiet --no-cache-dir --disable-pip-version-check --require-hashes --no-deps -r "$MCP_DIR/requirements.txt" \
    && "$TG_OPT/venv/bin/python" -c 'import telethon, mcp, httpx, qrcode'; then
    printf '%s\n' "$want_stamp" >"$TG_OPT/venv/.stamp"
    chmod -R go-w,a+rX "$TG_OPT/venv"
    changed "built $TG_OPT/venv (hash-pinned requirements, telegram-mcp $commit)"
  else
    warn "mcp: building the telegram-mcp venv failed"
    rm -rf -- "$TG_OPT/venv"
  fi
  [ "$was_active" -eq 1 ] && systemctl start telegram-mcp.service
  return 0
}

# tgconfirm: the owner-confirmation broker of Telegram sending (infrastructure/mcp/confirm). The user comes from the users section
# (managed.tsv row: service, noacl, nobecome, create, wayland = the Wayland socket ACL of `usr clipboard-acl`). Files go to
# /usr/local/lib/tgconfirm: broker.py, popup.py, keymap.tsv (twins of the code keys, from .config/layout), ghostty.conf (the
# palette of themes/generated/black + the popup config); the unit gets a rendered drop-in with the owner's uid. The service only
# starts once `mcp-telegram-setup send-chats` stored tgconfirm.send_token.
CONFIRM_DIR="$INFRA/mcp/confirm"
TGC_LIB=/usr/local/lib/tgconfirm
mcp_tgconfirm() {
  local f tmp tmp2 uid wl dropin=/etc/systemd/system/tgconfirm.service.d/10-owner.conf
  uid="$(id -u "$OWNER")"
  if ! getent passwd tgconfirm >/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] tgconfirm does not exist yet: the users section creates it (service, noacl, nobecome, wayland)"
    else
      warn "mcp: the service user tgconfirm does not exist; run: sudo $0 --only users,mcp (owner-confirmed Telegram sending was not set up)"
      return 0
    fi
  fi
  for f in broker.py popup.py; do
    install_file "$CONFIRM_DIR/$f" "$TGC_LIB/$f" 755
  done
  install_file "$REPO/.config/layout/keymap.tsv" "$TGC_LIB/keymap.tsv" 644
  tmp="$(mktemp)"
  cat "$REPO/themes/generated/black/ghostty.conf" "$CONFIRM_DIR/ghostty-popup.conf" >"$tmp"
  install_file "$tmp" "$TGC_LIB/ghostty.conf" 644
  tmp2="$(mktemp)"
  printf '# rendered by apply-system.sh --only mcp: the only uid that may ask the broker for a popup\n[Service]\nEnvironment=TGCONFIRM_OWNER_UID=%s\n' "$uid" >"$tmp2"
  install_file "$tmp2" "$dropin" 644
  rm -f "$tmp" "$tmp2"
  install_file "$CONFIRM_DIR/tgconfirm.service" /etc/systemd/system/tgconfirm.service
  run systemctl daemon-reload
  if [ "$DRY_RUN" -eq 0 ] && command -v systemd-analyze >/dev/null; then
    systemd-analyze verify /etc/systemd/system/tgconfirm.service >/dev/null 2>&1 || warn "mcp: systemd-analyze verify reports a problem in tgconfirm.service"
  fi
  try systemctl enable tgconfirm.service
  if [ "$DRY_RUN" -eq 0 ] && [ -e "$CREDSTORE/tgconfirm.send_token" ]; then
    try systemctl restart tgconfirm.service
    changed "tgconfirm.service (re)started (send token present)"
  else
    log "tgconfirm.service enabled but not started: its send token is stored by mcp-telegram-setup send-chats"
  fi
  # the Wayland socket ACL for tgconfirm in the running session (Hyprland's autostart repeats it at every login)
  wl="$(ls "/run/user/$uid" 2>/dev/null | grep -m1 -E '^wayland-[0-9]+$' || true)"
  if { [ -n "$wl" ] && getent passwd tgconfirm >/dev/null; } || [ "$DRY_RUN" -eq 1 ]; then
    run_as_owner env "XDG_RUNTIME_DIR=/run/user/$uid" "WAYLAND_DISPLAY=${wl:-wayland-1}" "$REPO/.local/bin/usr" clipboard-acl
  fi
  changed "tgconfirm broker, popup, ghostty config and unit installed"
  followup "mcp-telegram-setup send-chats    # one time: tick the chats the AI may SEND to (Bitwarden master password if locked, sudo password)"
  followup "mcp-telegram-send on             # when you want agents to be able to ask: you confirm in a popup, auto-off after 60 minutes"
}

section_mcp() {
  header "mcp"
  local p pkgs=(chromium whisper-cpp) f unit all_creds=1 k
  if [ ! -r "$MCP_DIR/pins.env" ]; then
    warn "mcp: $MCP_DIR/pins.env is missing, nothing to do"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$MCP_DIR/pins.env"

  # 1. packages
  for p in "${pkgs[@]}"; do
    if pkg_installed_exact "$p"; then log "unchanged: $p is installed"; else try pacman -S --needed --noconfirm "$p"; fi
  done
  mcp_retire_hub

  # 2. Telegram MCP needs the service user from the users section
  if ! getent passwd aimcp >/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] aimcp does not exist yet: the users section creates it (service, noacl, nobecome); a real run of --only users,mcp does both"
    else
      warn "mcp: the service user aimcp does not exist; run: sudo $0 --only users,mcp (nothing of the Telegram service was set up)"
      return 0
    fi
  fi

  mcp_whisper_model
  mcp_telegram_source || return 0

  # 3. runtime scripts and units
  for f in run serve.py creds-install login.py; do
    install_file "$MCP_DIR/$f" "$TG_LIB/$f" 755
  done
  # drop-in with the optional send credentials (installed into telegram-mcp.service.d only while both exist)
  install_file "$MCP_DIR/send.conf" "$TG_LIB/send.conf" 644
  run install -d -m 700 "$CREDSTORE"
  for unit in telegram-mcp.service telegram-whisper.service telegram-whisper-proxy.service telegram-whisper-proxy.socket; do
    install_file "$MCP_DIR/$unit" "/etc/systemd/system/$unit"
  done
  if [ -e "$CREDSTORE/telegram-mcp.send_token" ] && [ -e "$CREDSTORE/telegram-mcp.send_allowlist" ]; then
    run "$TG_LIB/creds-install" --sync    # send drop-in (owner-confirmed sending) follows the credentials that exist
  fi
  run systemctl daemon-reload
  if [ "$DRY_RUN" -eq 0 ] && command -v systemd-analyze >/dev/null; then
    systemd-analyze verify /etc/systemd/system/telegram-mcp.service >/dev/null 2>&1 || warn "mcp: systemd-analyze verify reports a problem in telegram-mcp.service"
  fi
  try systemctl enable --now telegram-whisper-proxy.socket
  try systemctl enable telegram-mcp.service
  for k in api_id api_hash session allowlist token; do
    [ -e "$CREDSTORE/telegram-mcp.$k" ] || all_creds=0
  done
  if [ "$DRY_RUN" -eq 0 ] && [ "$all_creds" -eq 1 ]; then
    try systemctl restart telegram-mcp.service
    changed "telegram-mcp.service (re)started (credentials present)"
  else
    log "telegram-mcp.service enabled but not started: the credentials are stored by mcp-telegram-setup"
  fi
  changed "telegram-mcp units, scripts and credstore directory installed"
  followup "mcp-telegram-setup    # one time, in a terminal: QR login, tick the chats, sudo password; stores the session in Bitwarden + the TPM2 credstore and starts the service"
  followup "mcp-add               # once: registers the gateway servers (desktop-ro, chrome-devtools, telegram, ...) in Claude Code and Codex"
  followup "systemctl status telegram-mcp telegram-whisper-proxy.socket; mcp-gateway status"
  mcp_tgconfirm
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
  if [ "$GREETER_BANNER" -eq 1 ]; then
    greeter_banner
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
    if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$s,"* ]]; then
      continue
    fi
    "section_$s"
  done
  # a single-section run has no summary: print the login screen note here
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",summary,"* ]] && [ "$GREETER_BANNER" -eq 1 ]; then
    greeter_banner
  fi
}

main
