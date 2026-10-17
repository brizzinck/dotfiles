#!/usr/bin/env bash
# Build helper for the local package everforest-cursor-theme (PKGBUILD next to this file). Run as a normal user:
# makepkg refuses root, and the build needs no privileges. Installing is a separate `pacman -U` (apply-system.sh does it as
# root after running `build.sh --build` as the owner; install.sh uses `--install`, which asks for sudo only for pacman -U).
#
#   build.sh --stamp              print the build stamp: sha256 of PKGBUILD + the rendered pointer.json
#   build.sh --installed-current  exit 0 when the installed theme was built from the current stamp (nothing to do)
#   build.sh --build OUTDIR       build the package into OUTDIR (makepkg, no install); prints the package path
#   build.sh --install            --build into a temp dir, then `sudo pacman -U` it (skipped when up to date)
#   --dry-run (with --build/--install)  print what would happen
# Colours: themes/generated/black/pointer.json (rendered by themes/palette/render.py from the palette tokens green, bg_oled;
# black and night are identical, the pointer does not follow the theme variant).
set -u

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PKGDIR="$HERE/everforest-cursor-theme"
POINTER="$REPO/themes/generated/black/pointer.json"
ICONS="${EVERFOREST_ICONS_DIR:-/usr/share/icons}"
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

theme_name() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$POINTER"; }
stamp() { cat "$PKGDIR/PKGBUILD" "$POINTER" | sha256sum | cut -d' ' -f1; }

installed_current() {
  local f
  f="$ICONS/$(theme_name)/.build-stamp"
  [[ -r $f && $(<"$f") == "$(stamp)" ]]
}

build() {
  local out=$1 work missing
  [[ -r $POINTER ]] || { echo "build.sh: $POINTER missing (run themes/palette/render.py)" >&2; return 1; }
  [[ $(id -u) -ne 0 ]] || { echo "build.sh: run as a normal user (makepkg refuses root)" >&2; return 1; }
  # no -s: makedepends must already be installed (apply-system.sh installs them before calling this)
  missing=""
  [[ -n ${EVERFOREST_SKIP_DEPS:-} ]] || missing=$(pacman -T git python librsvg xorg-xcursorgen)   # test hook: tools on PATH
  if [[ -n $missing ]]; then
    echo "build.sh: missing build dependencies: $(tr '\n' ' ' <<<"$missing") (sudo pacman -S --needed git python librsvg xorg-xcursorgen)" >&2
    return 3
  fi
  if ((DRY)); then
    echo "would build everforest-cursor-theme (stamp $(stamp)) with makepkg in a temp dir and copy the package to $out"
    return 0
  fi
  work=$(mktemp -d "${TMPDIR:-/tmp}/everforest-cursor.XXXXXX")
  cp "$PKGDIR/PKGBUILD" "$POINTER" "$work/"
  stamp >"$work/build-stamp"
  mkdir -p "$out"
  if (cd "$work" && PKGDEST="$out" makepkg -f --noconfirm ${EVERFOREST_SKIP_DEPS:+-d} >"$work/makepkg.log" 2>&1); then
    rm -rf -- "$work"
    find "$out" -maxdepth 1 -name 'everforest-cursor-theme-*.pkg.tar.*' ! -name '*.sig' -print -quit
  else
    echo "build.sh: makepkg failed, log: $work/makepkg.log" >&2
    tail -n 15 "$work/makepkg.log" >&2
    return 1
  fi
}

case ${1:-} in
  --stamp) stamp ;;
  --installed-current) installed_current ;;
  --build) build "${2:?usage: build.sh --build OUTDIR}" ;;
  --install)
    if installed_current; then echo "everforest-cursor-theme is up to date"; exit 0; fi
    if ((DRY)); then build /nonexistent; echo "would run: sudo pacman -U --noconfirm <package>"; exit 0; fi
    out=$(mktemp -d "${TMPDIR:-/tmp}/everforest-cursor-pkg.XXXXXX")
    pkg=$(build "$out") || { rm -rf -- "$out"; exit 1; }
    sudo pacman -U --noconfirm "$pkg"
    rc=$?
    rm -rf -- "$out"
    exit $rc ;;
  *) echo "usage: build.sh --stamp | --installed-current | --build OUTDIR | --install [--dry-run]" >&2; exit 2 ;;
esac
