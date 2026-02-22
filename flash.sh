#!/bin/bash
#
# Download Arch Linux ISO and flash it to USB (/dev/xxx)
# Run as root on any Linux machine
# WARNING: DESTROYS ALL DATA ON /dev/xxx

set -e

DISK="$1"
ISO_URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
ISO_FILE="/tmp/archlinux.iso"

echo "Target disk: $DISK"
lsblk $DISK
echo ""
read -p "!!! This will WIPE $DISK. Are you sure? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 1

echo "Unmounting $DISK partitions..."
umount ${DISK}* 2>/dev/null || true

echo "Downloading Arch Linux ISO..."
curl -L --progress-bar "$ISO_URL" -o "$ISO_FILE"

echo "Flashing ISO to $DISK (this may take a few minutes)..."
dd if="$ISO_FILE" of="$DISK" bs=4M status=progress oflag=sync

echo ""
echo " Done! Arch ISO flashed to $DISK"
echo " You can now boot from the USB."

rm -f "$ISO_FILE"
