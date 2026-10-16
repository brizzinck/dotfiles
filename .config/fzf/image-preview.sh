#!/usr/bin/env bash
# image-preview.sh FILE: draw an image into the fzf preview pane (used by `fzf-menu --image`, clipboard, windows).
#
# ghostty speaks the kitty graphics protocol. fzf can show such images only through Unicode placeholders (the image
# is transmitted once and the pane holds ordinary text cells that the terminal paints over), which is what
# `kitten icat --unicode-placeholder` emits; kitten is not installed, so chafa renders and this script unwraps its
# placeholder output (chafa only emits placeholders in its tmux passthrough mode; the tmux DCS wrapper is removed).
# Inside tmux (no graphics) or with FZF_MENU_IMAGE=symbols the image is drawn with character cells instead.
#
#   image-preview.sh FILE            uses $FZF_PREVIEW_COLUMNS x $FZF_PREVIEW_LINES (set by fzf)
#   FZF_MENU_IMAGE=symbols|kitty     force a renderer
set -u
file=${1:-}
[[ -n $file && -f $file ]] || { printf 'no image: %s\n' "${file:-?}"; exit 0; }
command -v chafa >/dev/null 2>&1 || { printf 'chafa is not installed (%s)\n' "$file"; exit 0; }
cols=${FZF_PREVIEW_COLUMNS:-60}
lines=${FZF_PREVIEW_LINES:-20}

mode=${FZF_MENU_IMAGE:-auto}
if [[ $mode == auto ]]; then
  if [[ -z ${TMUX:-} && -n ${GHOSTTY_RESOURCES_DIR:-}${GHOSTTY_BIN_DIR:-} ]]; then mode=kitty; else mode=symbols; fi
fi

if [[ $mode == kitty ]]; then
  chafa -f kitty --passthrough=tmux --animate=off -s "${cols}x${lines}" "$file" 2>/dev/null |
    python3 -I -c '
import re, sys
data = sys.stdin.buffer.read()
def unwrap(m):
    return m.group(1).replace(b"\x1b\x1b", b"\x1b")
data = re.sub(rb"\x1bPtmux;((?:[^\x1b]|\x1b\x1b)*)\x1b\\", unwrap, data, flags=re.S)
sys.stdout.buffer.write(data)'
else
  chafa -f symbols --animate=off -s "${cols}x${lines}" "$file" 2>/dev/null
fi
