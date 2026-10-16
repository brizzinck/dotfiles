#!/usr/bin/env bash
# Waybar custom/recording: shows REC while gpu-screen-recorder runs (process name is truncated to 15 chars).
if pgrep -x gpu-screen-reco >/dev/null; then
  echo '{"text":"󰑊 REC","class":"rec"}'
else
  echo '{"text":""}'
fi
