#!/usr/bin/env bash
# Bound to Enter in keymap.toml. Media files publish a DDS event that
# yazi.nvim forwards to Neovim (utils/mpv.lua plays it), leaving yazi open --
# yazi's own `open` action always closes the embedded window first, which is
# fine for editing a file but not for "peek at this video/audio and keep
# browsing". Everything else falls through to yazi's normal open.
ext="$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')"

case "$ext" in
  mp4 | mkv | webm | mov | avi | m4v | flv | wmv | mp3 | wav | flac | ogg | m4a | opus)
    ya pub-to 0 play-media --str "$1"
    ;;
  *)
    ya emit open
    ;;
esac
