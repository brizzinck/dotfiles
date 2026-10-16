#!/usr/bin/env bash
# Waybar custom/vpn: shown only while a VPN/tunnel interface is up (OpenVPN/WireGuard/Pritunl/Surfshark/Tailscale).
# Daemons (v2rayA, happd, pritunl-client-service) run all the time, so only interfaces count.
devs=$(ip -br link 2>/dev/null |
  awk '$1 ~ /^(tun|tap|wg|tailscale|pritunl|surfshark|proton|nordlynx|utun)/ && ($2 == "UP" || $2 == "UNKNOWN") {print $1}')
if [[ -n $devs ]]; then
  jq -cn --arg d "$devs" '{text: "󰦝 VPN", class: "on", tooltip: $d}'
else
  echo '{"text":""}'
fi
