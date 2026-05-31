#!/bin/bash
set -e
FW_PATH=/var/lib/firmware/aic8800D80
KO_DIR=/usr/local/lib/aic8800

# Fix SELinux labels on .ko files (needed after recompilation)
chcon -t modules_object_t "$KO_DIR"/*.ko 2>/dev/null || true

# Set kernel firmware search path
echo "$FW_PATH" > /sys/module/firmware_class/parameters/path

# Load dependencies first
for mod in cfg80211 bluetooth rfkill; do
    if ! lsmod | grep -q "^$mod"; then
        modprobe "$mod"
    fi
done

# Load AIC modules if not already loaded
if ! lsmod | grep -q '^aic_load_fw'; then
    insmod "$KO_DIR/aic_load_fw.ko" aic_fw_path="$FW_PATH"
fi
if ! lsmod | grep -q '^aic8800_fdrv'; then
    insmod "$KO_DIR/aic8800_fdrv.ko"
fi
if ! lsmod | grep -q '^aic_btusb'; then
    insmod "$KO_DIR/aic_btusb.ko"
fi
