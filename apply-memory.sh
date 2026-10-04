#!/usr/bin/env bash
# Apply the RAM safety net (infrastructure/memory/*) to /etc. Idempotent; safe to rerun.
set -euo pipefail

[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/infrastructure/memory"

pacman -S --needed --noconfirm zram-generator

install -Dm644 "$SRC/zram-generator.conf"    /etc/systemd/zram-generator.conf
install -Dm644 "$SRC/99-dotfiles-memory.conf" /etc/sysctl.d/99-dotfiles-memory.conf
install -Dm644 "$SRC/zswap-off.conf"         /etc/tmpfiles.d/zswap-off.conf
install -Dm644 "$SRC/journald-size.conf"     /etc/systemd/journald.conf.d/size.conf
[ -e /etc/docker/daemon.json ] || install -Dm644 "$SRC/docker-daemon.json" /etc/docker/daemon.json

systemd-tmpfiles --create /etc/tmpfiles.d/zswap-off.conf
sysctl --system >/dev/null
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service
systemctl restart systemd-journald.service

echo "--- swap ---";   swapon --show
echo "--- zswap enabled (want N) ---"; cat /sys/module/zswap/parameters/enabled
echo "Docker log limits apply after: sudo systemctl restart docker"
