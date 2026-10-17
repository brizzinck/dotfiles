#!/usr/bin/env bash
# Obsidian: the vault snippet snippets/everforest.css is a link to `current/obsidian.css`; Obsidian only re-reads a snippet
# when its directory entry changes, and a flip of `current` does not touch that link, so touch the link itself
# (touch -h, the file is not modified): a running Obsidian reloads the colours at once, a closed one reads them at start.
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"   # <dotfiles>/.config/theme/hooks.d
link="$here/../../../apps/obsidian/vault-config/snippets/everforest.css"
[[ -L $link ]] || exit 0
touch -h "$link" && echo "obsidian: snippet touched"
exit 0
