#!/usr/bin/env bash
# Obsidian configuration lives here, the notes live in the private repo (brizzinck/obsidian). For every vault this makes:
#   <vault>/.obsidian        -> apps/obsidian/vault-config           (one directory symlink: Obsidian writes its settings straight
#                                                                     into the dotfiles tree; vault-config/.gitignore keeps the
#                                                                     volatile, per-device and downloaded files out of git)
#   vault-config/plugins/<id>/  the pinned community plugins from plugins.tsv, downloaded from GitHub and hash-verified
#                               (plugins.sh); plugin settings (plugins/<id>/data.json) are tracked
#   vault-config/snippets/everforest.css -> ~/.local/state/theme/current/obsidian.css   (the palette follows `theme black|night`;
#                               enabled in vault-config/appearance.json)
#   <vault>/.obsidian.vimrc  -> .obsidian/obsidian.vimrc             (apps/obsidian/obsidian.vimrc + generated ua/ru twins, built
#                               here on every run, read by the plugin "Vimrc Support", which is in plugins.tsv)
# Everything it replaces (a real .obsidian folder, a vimrc it did not write) is moved to
# ${XDG_DATA_HOME:-~/.local/share}/dotfiles-backups/obsidian/<time>-<vault>/ first; files of the old folder that the dotfiles
# do not have (workspace.json, hand-installed plugins and themes) are copied into vault-config (git-ignored there).
# Idempotent. A real .obsidian folder is not swapped while Obsidian runs (close it, run this again); everything else is safe.
# Vaults: --vault PATH (repeatable), plain PATH arguments, $OBSIDIAN_VAULT, else the vault list of Obsidian
# (~/.config/obsidian/obsidian.json). A vault directory without .obsidian is fine (fresh clone of the notes repo).
# Usage: apps/obsidian/apply.sh [--dry-run] [--no-download] [--vault PATH]...        called by install.sh
#   fresh machine (private stage B1): git clone git@github.com:brizzinck/obsidian.git ~/job/obsidian, then
#   apps/obsidian/apply.sh --vault ~/job/obsidian/knowledge   (registers the vault in Obsidian's list when it is missing)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SRC/vault-config"
DRY=0
DL=1
vaults=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-download) DL=0 ;;
    --vault) shift; [ $# -gt 0 ] || { echo "apply.sh: --vault needs a path" >&2; exit 2; }; vaults+=("$1") ;;
    --vault=*) vaults+=("${1#--vault=}") ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "apply.sh: unknown option $1" >&2; exit 2 ;;
    *) vaults+=("$1") ;;
  esac
  shift
done
explicit=${#vaults[@]}
[ -n "${OBSIDIAN_VAULT:-}" ] && vaults+=("$OBSIDIAN_VAULT") && explicit=1
LIST="${OBSIDIAN_LIST:-$HOME/.config/obsidian/obsidian.json}"   # Obsidian's vault list (OBSIDIAN_LIST: tests)
STATE_THEME="$HOME/.local/state/theme/current"
BACKUPS="${XDG_DATA_HOME:-$HOME/.local/share}/dotfiles-backups/obsidian"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARK='" >>> dotfiles-managed obsidian.vimrc (apps/obsidian/apply.sh): rebuilt on every run, edit apps/obsidian/obsidian.vimrc instead'

say() { printf '  %s\n' "$*"; }
act() { if [ "$DRY" = 1 ]; then say "would: $*"; return 1; fi; return 0; }   # act "text" && do-it
command -v jq >/dev/null 2>&1 || { say "obsidian: jq is needed, skipped"; exit 0; }

if [ ${#vaults[@]} -eq 0 ] && [ -f "$LIST" ]; then
  while IFS= read -r p; do [ -n "$p" ] && vaults+=("$p"); done < <(jq -r '.vaults[]?.path // empty' "$LIST" 2>/dev/null)
fi
if [ ${#vaults[@]} -eq 0 ]; then say "obsidian: no vault found (open one in Obsidian once, or pass --vault DIR), skipped"; exit 0; fi

running() { pgrep -x obsidian >/dev/null 2>&1; }

# --- vault-independent parts: plugins, snippet link, vimrc build --------------------------------------------------------
say "obsidian config: $CFG"
if [ "$DL" = 1 ] && [ "$DRY" = 0 ]; then
  "$SRC/plugins.sh" install "$CFG" || say "plugins: not everything could be installed (offline? rerun later)"
else
  "$SRC/plugins.sh" check "$CFG" | sed 's/^/  would: fix /' || true
fi

mkdir -p "$CFG/snippets" 2>/dev/null || true
snip="$CFG/snippets/everforest.css"
if [ "$(readlink "$snip" 2>/dev/null)" = "$STATE_THEME/obsidian.css" ]; then
  say "snippet everforest.css already linked"
elif act "link snippets/everforest.css -> $STATE_THEME/obsidian.css"; then
  ln -sfn "$STATE_THEME/obsidian.css" "$snip"; say "snippet everforest.css linked to the active theme variant"
fi
[ "$DRY" = 1 ] || [ -e "$snip" ] || say "  note: $STATE_THEME/obsidian.css does not exist yet (run: theme init)"

new="$(mktemp)"
{ printf '%s\n' "$MARK"; cat "$SRC/obsidian.vimrc"; printf '\n'; cat "$SRC/vimrc-twins.txt"; } >"$new"
if [ -f "$CFG/obsidian.vimrc" ] && cmp -s "$new" "$CFG/obsidian.vimrc"; then say "obsidian.vimrc already up to date"
elif act "write vault-config/obsidian.vimrc"; then cat "$new" >"$CFG/obsidian.vimrc"; say "obsidian.vimrc written"; fi
rm -f "$new"

# --- per vault ----------------------------------------------------------------------------------------------------------
backup_dir() { echo "$BACKUPS/$STAMP-$(basename "$1")"; }

# copy what the old real .obsidian has and vault-config lacks (cp -n: never overwrites the tracked settings)
adopt_old() {   # OLD_DIR
  local old="$1" item
  for item in "$old"/* "$old"/.[!.]*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in snippets|plugins|themes) continue ;; esac
    cp -a -n "$item" "$CFG/" 2>/dev/null || true
  done
  for sub in plugins themes snippets; do
    [ -d "$old/$sub" ] || continue
    mkdir -p "$CFG/$sub"
    for item in "$old/$sub"/*; do
      [ -e "$item" ] || continue
      [ -e "$CFG/$sub/$(basename "$item")" ] || [ -L "$CFG/$sub/$(basename "$item")" ] || cp -a "$item" "$CFG/$sub/"
    done
  done
}

register_vault() {   # PATH: add the vault to Obsidian's own list when it is not there (never while Obsidian runs)
  local v="$1" id
  [ -f "$LIST" ] || { act "create $LIST with the vault" && { mkdir -p "$(dirname "$LIST")"; echo '{"vaults":{}}' >"$LIST"; }; } || true
  [ -f "$LIST" ] || return 0
  if jq -e --arg p "$v" '[.vaults[]?.path] | index($p)' "$LIST" >/dev/null 2>&1; then return 0; fi
  if running; then say "  vault is not in Obsidian's list; close Obsidian and run this again to register it"; return 0; fi
  if act "register $v in $LIST"; then
    id="$(printf '%s' "$v" | sha256sum | cut -c1-16)"
    jq --arg id "$id" --arg p "$v" '.vaults[$id] = {path: $p, ts: (now * 1000 | floor)}' "$LIST" >"$LIST.tmp" && mv "$LIST.tmp" "$LIST"
    say "  vault registered in Obsidian's list"
  fi
}

seen=""
for v in "${vaults[@]}"; do
  v="${v%/}"
  case "$seen" in *"|$v|"*) continue ;; esac
  seen="$seen|$v|"
  if [ ! -d "$v" ]; then say "obsidian: $v is not a directory, skipped"; continue; fi
  say "obsidian: $v"
  cfgl="$v/.obsidian"
  if [ -L "$cfgl" ] && [ "$(readlink -f "$cfgl")" = "$(readlink -f "$CFG")" ]; then
    say "  .obsidian already links to the dotfiles"
  elif [ -L "$cfgl" ]; then
    if act "re-point .obsidian (-> $(readlink "$cfgl")) to $CFG"; then ln -sfn "$CFG" "$cfgl"; say "  .obsidian re-pointed to the dotfiles"; fi
  elif [ -d "$cfgl" ]; then
    if running; then say "  .obsidian is a real folder and Obsidian is running: close it, run this again"; continue; fi
    if act "move the real .obsidian to $(backup_dir "$v") and link it to $CFG"; then
      b="$(backup_dir "$v")"; mkdir -p "$b"
      cp -a "$cfgl" "$b/.obsidian"
      adopt_old "$cfgl"
      rm -rf "$cfgl"
      ln -s "$CFG" "$cfgl"
      say "  .obsidian now links to the dotfiles (old folder kept in $b/.obsidian)"
    fi
  elif [ -e "$cfgl" ]; then
    say "  $cfgl exists and is not a folder, skipped"; continue
  elif act "link .obsidian -> $CFG"; then
    ln -s "$CFG" "$cfgl"; say "  .obsidian linked to the dotfiles"
  fi

  vimrc="$v/.obsidian.vimrc"
  if [ -L "$vimrc" ] && [ "$(readlink "$vimrc")" = ".obsidian/obsidian.vimrc" ]; then
    say "  .obsidian.vimrc already linked"
  elif act "link .obsidian.vimrc -> .obsidian/obsidian.vimrc"; then
    if [ -f "$vimrc" ] && [ ! -L "$vimrc" ] && ! grep -qF '>>> dotfiles-managed obsidian.vimrc' "$vimrc"; then
      b="$(backup_dir "$v")"; mkdir -p "$b"; cp -p "$vimrc" "$b/.obsidian.vimrc"; say "  kept your vimrc in $b/.obsidian.vimrc"
    fi
    ln -sfn ".obsidian/obsidian.vimrc" "$vimrc"; say "  .obsidian.vimrc linked"
  fi

  [ "$explicit" = 0 ] || register_vault "$v"
done
if running; then say "obsidian is running: restart it to pick the changes up"; fi
exit 0
