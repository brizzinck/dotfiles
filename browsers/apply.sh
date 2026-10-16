#!/usr/bin/env bash
# Copy the tracked browser settings into the flatpak sandboxes (idempotent, merges, never overwrites foreign lines).
#   zen/user.js              -> <active Zen profile>/user.js   (managed block between the dotfiles-managed markers)
#   chrome/chrome-flags.conf -> ~/.var/app/com.google.Chrome/config/chrome-flags.conf   (one flag per line, matched by --name)
# Copies instead of symlinks: the Chrome flatpak has no access to ~/dotfiles, and Zen would lose the file if its profile is recreated.
# Changes apply on the next browser start. Usage: browsers/apply.sh [--dry-run]
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
BEGIN='// >>> dotfiles-managed'
END='// <<< dotfiles-managed'

say() { printf '  %s\n' "$*"; }

# Resolve the Zen profile the app actually uses: for every profiles.ini take the locked Install default (else Default=1),
# keep the ones that already have a prefs.js and pick the most recently written.
zen_profile() {
  local ini base path best="" best_m=0 m dir
  for ini in "$HOME/.var/app/app.zen_browser.zen/config/zen/profiles.ini" \
             "$HOME/.var/app/app.zen_browser.zen/.zen/profiles.ini" \
             "$HOME/.zen/profiles.ini" "$HOME/.config/zen/profiles.ini"; do
    [ -f "$ini" ] || continue
    base="$(dirname "$ini")"
    path="$(awk -F= '/^\[Install/{i=1;next} /^\[/{i=0} i&&$1=="Default"{print $2; exit}' "$ini")"
    [ -n "$path" ] || path="$(awk -F= '/^\[Profile/{p=""} $1=="Path"{p=$2} $1=="Default"&&$2=="1"{print p; exit}' "$ini")"
    [ -n "$path" ] || continue
    dir="$base/$path"
    [ -f "$dir/prefs.js" ] || continue
    m="$(stat -c %Y "$dir/prefs.js")"
    if [ "$m" -gt "$best_m" ]; then best_m="$m"; best="$dir"; fi
  done
  printf '%s' "$best"
}

apply_zen() {
  local dir target tmp
  dir="$(zen_profile)"
  if [ -z "$dir" ]; then say "zen: no profile with prefs.js found, skipped"; return 0; fi
  target="$dir/user.js"
  say "zen: $target"
  [ "$DRY" = 1 ] && return 0
  tmp="$(mktemp)"
  if [ -f "$target" ]; then
    # keep every foreign line, drop an earlier managed block
    awk -v b="$BEGIN" -v e="$END" 'index($0,b)==1{skip=1} !skip{print} index($0,e)==1{skip=0}' "$target" > "$tmp"
  fi
  cat "$SRC/zen/user.js" >> "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; say "zen: already up to date"; return 0; fi
  cat "$tmp" > "$target"; rm -f "$tmp"
  say "zen: user.js written (takes effect on the next Zen start)"
}

apply_chrome() {
  local cfg="$HOME/.var/app/com.google.Chrome/config" target tmp line key
  if [ ! -d "$cfg" ]; then say "chrome: flatpak config dir missing, skipped"; return 0; fi
  target="$cfg/chrome-flags.conf"
  say "chrome: $target"
  [ "$DRY" = 1 ] && return 0
  tmp="$(mktemp)"
  [ -f "$target" ] && cat "$target" > "$tmp"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    # drop an older value of the same flag (exact name, with or without =value), then append ours
    awk -v k="$key" '{ split($0, a, "="); if (a[1] != k) print }' "$tmp" > "$tmp.n"
    mv "$tmp.n" "$tmp"
    printf '%s\n' "$line" >> "$tmp"
  done < "$SRC/chrome/chrome-flags.conf"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; say "chrome: already up to date"; return 0; fi
  cat "$tmp" > "$target"; rm -f "$tmp"
  say "chrome: flags written (takes effect on the next Chrome start)"
}

apply_zen
apply_chrome
