#!/usr/bin/env bash
# Waybar custom/recording: shows REC while gpu-screen-recorder runs (process name is truncated to 15 chars).
# rec-toggle.sh leaves $XDG_RUNTIME_DIR/rec-mic behind when the microphone is part of the recording.
if pgrep -x gpu-screen-reco >/dev/null; then
  if [[ -e ${XDG_RUNTIME_DIR:-/tmp}/rec-mic ]]; then
    echo '{"text":"󰑊 REC+mic","class":"rec","tooltip":"Recording system sound and microphone"}'
  else
    echo '{"text":"󰑊 REC","class":"rec"}'
  fi
else
  echo '{"text":""}'
fi
