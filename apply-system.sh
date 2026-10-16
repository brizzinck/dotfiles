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
  exec sudo "$0" "$@"
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
# shellcheck disable=SC2034  # OWNER_HOME and INFRA are used by the sections later stages fill in
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
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

# --- sections below are stubs; later stages fill them ------------------------

# S2: pacman -Syu --noconfirm (full upgrade before installs; sets need_reboot).
section_upgrade() {
  header "upgrade"
  log "(not implemented yet)"
}

# S2: install the consolidated package lists (repo + prebuilt AUR packages), then rerun the pacman cache trim.
section_install() {
  header "install"
  log "(package lists not implemented yet)"
  cleanup_pacman_cache post-install
}

# S2: snap stack + snapd, explicit removal list, then orphans (pacman -Qdtq at run time).
section_remove() {
  header "remove"
  log "(not implemented yet)"
}

# S2/S3+: install_file calls for infrastructure/<area>/* into /etc (pacman.conf, makepkg.conf, daemon.json, earlyoom, tlp, ...).
section_config() {
  header "config"
  log "(not implemented yet)"
}

# S2: enable system timers/services (earlyoom, fstrim, paccache, reflector, tlp); user units are not handled here.
section_services() {
  header "services"
  log "(not implemented yet)"
}

# S2: tune2fs reserved blocks, fstab mount options (+ findmnt --verify).
section_disk() {
  header "disk"
  log "(not implemented yet)"
}

# S2: GRUB_TIMEOUT and grub-mkconfig (also picks up amd-ucode).
section_boot() {
  header "boot"
  log "(not implemented yet)"
}

# S2: flatpak update -y.
section_flatpak() {
  header "flatpak"
  log "(not implemented yet)"
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
