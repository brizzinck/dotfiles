#!/usr/bin/env bash
# Build helper for the local wl-kbptr package (PKGBUILD next to this file; the AUR one needs opencv4, Arch has opencv 5).
# Run as a normal user: makepkg refuses root. Installing is a separate `pacman -U` (apply-system.sh does it as root after
# `build.sh --build` as the owner; install.sh uses `--install`, which asks for sudo only for pacman -U).
#
#   build.sh --installed-current  exit 0 when the installed wl-kbptr has the PKGBUILD's pkgver-pkgrel (nothing to do)
#   build.sh --build OUTDIR       build the package into OUTDIR (makepkg, no install); prints the package path
#   build.sh --install            --build into a temp dir, then `sudo pacman -U` it (skipped when up to date)
#   --dry-run (with --build/--install)  print what would happen
set -u

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

want_version() { sed -nE 's/^pkgver=(.*)$/\1/p' "$HERE/PKGBUILD" | head -n1 | tr -d '\n'; printf -- '-'; sed -nE 's/^pkgrel=(.*)$/\1/p' "$HERE/PKGBUILD" | head -n1; }
installed_current() {
  local have
  have=$(pacman -Q wl-kbptr 2>/dev/null | cut -d' ' -f2) || return 1
  [[ -n $have && $have == "$(want_version)" ]]
}

build() {
  local out=$1 work missing
  [[ $(id -u) -ne 0 ]] || { echo "build.sh: run as a normal user (makepkg refuses root)" >&2; return 1; }
  # no -s: dependencies must already be installed (apply-system.sh installs them before calling this)
  missing=$(pacman -T meson wayland-protocols cairo wayland libxkbcommon pixman)
  if [[ -n $missing ]]; then
    echo "build.sh: missing dependencies: $(tr '\n' ' ' <<<"$missing") (sudo pacman -S --needed --asdeps ...)" >&2
    return 3
  fi
  if ((DRY)); then
    echo "would build wl-kbptr $(want_version) (-Dopencv=disabled) with makepkg in a temp dir and copy the package to $out"
    return 0
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/wl-kbptr-build.XXXXXX")
  cp "$HERE/PKGBUILD" "$work/"
  mkdir -p "$out"
  if (cd "$work" && PKGDEST="$out" makepkg -f --noconfirm >"$work/makepkg.log" 2>&1); then
    rm -rf -- "$work"
    find "$out" -maxdepth 1 -name 'wl-kbptr-*.pkg.tar.*' ! -name '*.sig' -print -quit
  else
    echo "build.sh: makepkg failed, log: $work/makepkg.log" >&2
    tail -n 15 "$work/makepkg.log" >&2
    return 1
  fi
}

case ${1:-} in
  --installed-current) installed_current ;;
  --build) build "${2:?usage: build.sh --build OUTDIR}" ;;
  --install)
    if installed_current; then echo "wl-kbptr is up to date"; exit 0; fi
    if ((DRY)); then build /nonexistent; echo "would run: sudo pacman -U --noconfirm <package>"; exit 0; fi
    out=$(mktemp -d "${TMPDIR:-/tmp}/wl-kbptr-pkg.XXXXXX")
    pkg=$(build "$out") || { rm -rf -- "$out"; exit 1; }
    sudo pacman -U --noconfirm "$pkg"
    rc=$?
    rm -rf -- "$out"
    exit $rc ;;
  *) echo "usage: build.sh --installed-current | --build OUTDIR | --install [--dry-run]" >&2; exit 2 ;;
esac
