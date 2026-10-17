#!/usr/bin/env bash
# Pinned Obsidian community plugins (apps/obsidian/plugins.tsv): download the release assets from GitHub and verify sha256.
#   plugins.sh install [CONFIG_DIR]   download what is missing or differs into CONFIG_DIR/plugins/<id>/ (default: apps/obsidian/vault-config)
#   plugins.sh check   [CONFIG_DIR]   offline: every pinned file is present and matches its hash (exit 1 otherwise)
#   plugins.sh pin ID TAG             download release TAG of plugin ID, rewrite its row in plugins.tsv with the new hashes
#   plugins.sh list                   print the pins
# A file is only moved into place after its hash matched, so a failed or tampered download never replaces a working plugin.
# Plugin settings (data.json) are never touched.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="$HERE/plugins.tsv"
ASSETS=(main.js manifest.json styles.css)   # column order in plugins.tsv (fields 4, 5, 6)

say() { printf '  %s\n' "$*"; }
rows() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$TSV"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
fetch() { curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 -o "$2" "$1"; }   # URL OUTFILE

cmd="${1:-}"; shift || true
case "$cmd" in
  list) rows | column -t -s $'\t' ;;

  check|install)
    cfg="${1:-$HERE/vault-config}"
    rc=0
    while IFS=$'\t' read -r id repo tag h_main h_manifest h_styles; do
      want=("$h_main" "$h_manifest" "$h_styles")
      dir="$cfg/plugins/$id"
      for i in 0 1 2; do
        asset="${ASSETS[$i]}"; h="${want[$i]}"
        [ "$h" = "-" ] && continue
        f="$dir/$asset"
        if [ -f "$f" ] && [ "$(sha "$f")" = "$h" ]; then continue; fi
        if [ "$cmd" = check ]; then say "plugin $id $tag: $asset missing or differs"; rc=1; continue; fi
        mkdir -p "$dir"
        tmp="$(mktemp "$dir/.$asset.XXXXXX")"
        if ! fetch "https://github.com/$repo/releases/download/$tag/$asset" "$tmp"; then
          rm -f "$tmp"; say "plugin $id $tag: download of $asset failed"; rc=1; continue
        fi
        if [ "$(sha "$tmp")" != "$h" ]; then
          rm -f "$tmp"; say "plugin $id $tag: $asset hash mismatch (not installed)"; rc=1; continue
        fi
        chmod 644 "$tmp"; mv -f "$tmp" "$f"
        say "plugin $id $tag: $asset installed"
      done
      # stale optional asset of an older pin (the pin says the release has no styles.css)
      [ "$h_styles" = "-" ] && [ "$cmd" = install ] && rm -f "$dir/styles.css"
    done < <(rows)
    [ "$cmd" = install ] && [ "$rc" = 0 ] && say "plugins: all pinned plugins verified"
    exit "$rc"
    ;;

  pin)
    id="${1:?usage: plugins.sh pin ID TAG}"; tag="${2:?usage: plugins.sh pin ID TAG}"
    row="$(rows | awk -F'\t' -v id="$id" '$1==id')"
    [ -n "$row" ] || { echo "plugins.sh: $id is not in plugins.tsv (add a row first: id, repo, tag, -, -, -)" >&2; exit 1; }
    repo="$(printf '%s' "$row" | cut -f2)"
    work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
    hashes=()
    for asset in "${ASSETS[@]}"; do
      if fetch "https://github.com/$repo/releases/download/$tag/$asset" "$work/$asset" 2>/dev/null; then
        hashes+=("$(sha "$work/$asset")")
      elif [ "$asset" = styles.css ]; then hashes+=("-")
      else echo "plugins.sh: $repo $tag has no $asset" >&2; exit 1; fi
    done
    got="$(jq -r .id "$work/manifest.json")"
    [ "$got" = "$id" ] || { echo "plugins.sh: manifest id is '$got', not '$id'" >&2; exit 1; }
    new="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$id" "$repo" "$tag" "${hashes[0]}" "${hashes[1]}" "${hashes[2]}")"
    tmp="$(mktemp "$TSV.XXXXXX")"
    awk -F'\t' -v OFS='\t' -v id="$id" -v new="$new" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next} $1==id {print new; next} {print}' "$TSV" >"$tmp"
    chmod --reference="$TSV" "$tmp"; mv "$tmp" "$TSV"
    say "pinned $id $tag ($(jq -r .version "$work/manifest.json" ))"
    say "next: apps/obsidian/plugins.sh install   (or apps/obsidian/apply.sh), then commit apps/obsidian/plugins.tsv"
    ;;

  *) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
