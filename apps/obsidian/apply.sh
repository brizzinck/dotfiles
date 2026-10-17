#!/usr/bin/env bash
# Obsidian vim keys (idempotent, never touches the running app):
#   1. <vault>/.obsidian/app.json   "vimMode": true  (every other key is kept; the file is only rewritten when it changes)
#   2. <vault>/.obsidian.vimrc      apps/obsidian/obsidian.vimrc + vimrc-twins.txt (generated ua/ru twins), for the community
#                                   plugin "Vimrc Support" (obsidian-vimrc-support). A vimrc that this script did not write is
#                                   kept as .obsidian.vimrc.dotfiles-backup first.
# Vaults: the paths in Obsidian's own vault list (~/.config/obsidian/obsidian.json, the flatpak copy too) that have a
# .obsidian folder, or the vault directories given as arguments / in $OBSIDIAN_VAULT. The plugin itself is NOT installed here:
# Obsidian > Settings > Community plugins > Turn on community plugins > Browse > "Vimrc Support" > Install > Enable.
# Restart Obsidian afterwards (app.json is read at start; the vimrc is re-read by the plugin on start).
# Usage: apps/obsidian/apply.sh [--dry-run] [VAULT_DIR ...]      called by install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
vaults=()
for a in "$@"; do
  if [ "$a" = "--dry-run" ]; then DRY=1; else vaults+=("$a"); fi
done
[ -n "${OBSIDIAN_VAULT:-}" ] && vaults+=("$OBSIDIAN_VAULT")
MARK='" >>> dotfiles-managed obsidian.vimrc (apps/obsidian/apply.sh): rebuilt on every run, edit apps/obsidian/obsidian.vimrc instead'

say() { printf '  %s\n' "$*"; }

if [ ${#vaults[@]} -eq 0 ]; then
  for list in "$HOME/.config/obsidian/obsidian.json" "$HOME/.var/app/md.obsidian.Obsidian/config/obsidian/obsidian.json"; do
    [ -f "$list" ] || continue
    while IFS= read -r p; do [ -n "$p" ] && vaults+=("$p"); done < <(jq -r '.vaults[]?.path // empty' "$list" 2>/dev/null)
  done
fi
if [ ${#vaults[@]} -eq 0 ]; then say "obsidian: no vault found (open one in Obsidian once, or pass its directory), skipped"; exit 0; fi
command -v jq >/dev/null 2>&1 || { say "obsidian: jq is needed, skipped"; exit 0; }

build_vimrc() { { printf '%s\n' "$MARK"; cat "$SRC/obsidian.vimrc"; printf '\n'; cat "$SRC/vimrc-twins.txt"; }; }

seen=""
for v in "${vaults[@]}"; do
  v="${v%/}"
  case " $seen " in *" $v "*) continue ;; esac
  seen="$seen $v"
  if [ ! -d "$v/.obsidian" ]; then say "obsidian: $v has no .obsidian folder, skipped"; continue; fi
  say "obsidian: $v"
  app="$v/.obsidian/app.json"
  if [ -f "$app" ]; then
    if ! jq -e . "$app" >/dev/null 2>&1; then say "  app.json is not valid JSON, left alone"; app=""; fi
  fi
  if [ -n "$app" ]; then
    if [ -f "$app" ] && [ "$(jq -r '.vimMode // false' "$app")" = "true" ]; then
      say "  vimMode already on"
    elif [ "$DRY" = 1 ]; then
      say "  would set vimMode true in app.json"
    else
      tmp="$(mktemp "$app.XXXXXX")"
      if [ -f "$app" ]; then jq '.vimMode = true' "$app" >"$tmp"; else echo '{"vimMode": true}' >"$tmp"; fi
      if jq -e '.vimMode == true' "$tmp" >/dev/null 2>&1; then
        [ -f "$app" ] && chmod --reference="$app" "$tmp"
        mv "$tmp" "$app"
        say "  vimMode set in app.json"
      else rm -f "$tmp"; say "  could not update app.json"; fi
    fi
  fi
  target="$v/.obsidian.vimrc"
  new="$(mktemp)"
  build_vimrc >"$new"
  if [ -f "$target" ] && cmp -s "$new" "$target"; then
    say "  .obsidian.vimrc already up to date"
  elif [ "$DRY" = 1 ]; then
    say "  would write .obsidian.vimrc"
  else
    if [ -f "$target" ] && ! grep -qF '>>> dotfiles-managed obsidian.vimrc' "$target" && [ ! -e "$target.dotfiles-backup" ]; then
      cp -p "$target" "$target.dotfiles-backup"; say "  kept your vimrc as .obsidian.vimrc.dotfiles-backup"
    fi
    cat "$new" >"$target"
    say "  .obsidian.vimrc written"
  fi
  rm -f "$new"
done
if ! pgrep -x obsidian >/dev/null 2>&1; then :; else say "obsidian is running: restart it to pick the changes up"; fi
