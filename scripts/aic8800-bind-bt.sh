#!/bin/bash
sleep 2
# Unbind generic btusb from BT interface 0 if bound
if readlink /sys/bus/usb/devices/*:1.0/driver 2>/dev/null | grep -q btusb; then
    for iface in $(ls /sys/bus/usb/drivers/btusb/ 2>/dev/null | grep ":1.0"); do
        devid=$(cat /sys/bus/usb/devices/$iface/../idVendor 2>/dev/null)
        if [ "$devid" = "a69c" ]; then
            echo "$iface" > /sys/bus/usb/drivers/btusb/unbind 2>/dev/null || true
            sleep 1
            echo "$iface" > /sys/bus/usb/drivers/aic_btusb/bind 2>/dev/null || true
        fi
    done
fi
