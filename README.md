# AIC8800D80 USB WiFi+BT Dongle — Linux Support

Linux support for the **LGX/Pandora International 88M80** WiFi+BT USB dongle
(chip: AIC8800D80, USB CD-ROM ID `1111:1111`, WiFi+BT ID `a69c:8d81`).

**Status: WiFi ✅ Bluetooth ✅** (kernel 6.19, Bazzite 44 / immutable Fedora)

---

## The Problem

This dongle ships as a virtual CD-ROM (`1111:1111`) and requires a modeswitch
command to activate as a WiFi adapter.  Once switched, it needs the
out-of-tree AIC8800 kernel driver — but all community builds of that driver
have a **critical bug that silently breaks Bluetooth**: the BT firmware
patch-loading block is wrapped in `#if 0`.

This repo documents the reverse engineering that found the modeswitch command,
provides the working system integration files, and contains the driver patches.

---

## Device info

| Item | Value |
|------|-------|
| Chip | AIC8800D80, CHIP_REV_U03 (chip_id=7) |
| USB CD-ROM mode | `1111:1111` (Pandora International, Mass Storage) |
| USB firmware-loading mode | `a69c:8d80` (AIC Wlan, after modeswitch) |
| USB WiFi+BT mode | `a69c:8d81` (AICSemi AIC 8800D80) |
| BT address | `68:8F:C9:xx:xx:xx` (BR/EDR + LE, secure connections) |

### USB ID transition sequence

```
1111:1111  (CD-ROM, Pandora/LGX, Mass Storage)
    |  SCSI vendor cmd FD 00..00 F2  (modeswitch)
    v
a69c:8d80  (AIC firmware-loading mode)
    |  aic_load_fw.ko  (loads BT patches + WiFi firmware)
    v
a69c:8d81  (AIC8800D80 WiFi+BT)
    |  aic8800_fdrv.ko + aic_btusb.ko
    v
wlan0 + hci0
```

---

## Modeswitch

The modeswitch command was discovered by reverse engineering the Windows
`AicWifiService.exe` / `Usb_driver.dll` installer (see [`re/`](re/)).

`Usb_driver.dll::Set_CS1_0()` sends a 16-byte SCSI vendor command via the
Mass Storage bulk endpoint:

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

### Install modeswitch

```bash
# Install the Python modeswitch script
sudo install -m 755 modeswitch/88m80-modeswitch /usr/local/bin/

# Install udev rule + systemd service
sudo install -m 644 modeswitch/88-88m80-modeswitch.rules /etc/udev/rules.d/
sudo install -m 644 modeswitch/88m80-modeswitch@.service /etc/systemd/system/
sudo udevadm control --reload-rules
```

The udev rule uses `TAG+="systemd"` + `ENV{SYSTEMD_WANTS}` rather than a
plain `RUN+=` rule so that the script runs **after `local-fs.target`**.
This is required on immutable distros (Bazzite, Silverblue) where
`/usr/local` is a symlink into `/var` and is not mounted at udev time.

---

## Driver

Build from [BLUEMOON233/AIC8800-Linux-Driver](https://github.com/BLUEMOON233/AIC8800-Linux-Driver)
with the patches from [`patches/`](patches/) applied:

| Patch | What it fixes |
|-------|--------------|
| `0001-aic_load_fw-enable-bt-patch-loading-d80-u02-u03.patch` | BT firmware never loaded (`#if 0` guards) |
| `0002-aic8800_fdrv-replace-in_irq-with-hardirq_count-kernel-6.17.patch` | Build failure on kernel ≥ 6.17 |

For `aic_btusb`, use [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800)
source with `CONFIG_BLUEDROID=0` (see Radxa's `fix-aic_btusb-use-bluez-by-default.patch`).

### Firmware

Get firmware from [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800)
at commit `dd2afa18` or later (earlier firmware gives `rd_version_val=0` and
breaks BT silently).  Install to `/var/lib/firmware/aic8800D80/` (use
`/var/lib/firmware` on immutable distros; the driver hardcodes `/lib/firmware`
which is read-only on ostree systems).

The `fw/aic8800D80/` directory in this repo contains a copy of the Radxa
firmware for convenience.

### Install driver

```bash
# Install compiled modules (build yourself against your kernel)
sudo install -d /usr/local/lib/aic8800
sudo install -m 644 aic_load_fw.ko aic8800_fdrv.ko aic_btusb.ko /usr/local/lib/aic8800/

# Install firmware
sudo install -d /var/lib/firmware/aic8800D80
sudo install -m 644 fw/aic8800D80/*.bin /var/lib/firmware/aic8800D80/

# Install module loader + systemd service
sudo install -m 755 scripts/aic8800-load-driver.sh /usr/local/bin/
sudo install -m 755 scripts/aic8800-bind-bt.sh /usr/local/bin/
sudo install -m 644 systemd/aic8800-driver.service /etc/systemd/system/
sudo install -m 644 udev/89-88m80-bt.rules /etc/udev/rules.d/
sudo systemctl enable --now aic8800-driver.service
sudo udevadm control --reload-rules
```

---

## Bug fixes documented

### BT never works: `#if 0` in aic_compat_8800d80.c

The BLUEMOON233 and goecho community drivers wrap the entire BT
patch-loading block in `#if 0`.  This means `fw_patch_table`,
`fw_adid`, `fw_patch`, and `fw_patch_ext0` are never uploaded before
the main firmware, so BT is non-functional on all U02/U03 hardware.

The Radxa driver has this fixed.  Patch: `0001-aic_load_fw-enable-bt-patch-loading-d80-u02-u03.patch`.

### Kernel 6.17+ build: `in_irq()` removed

`in_irq()` was removed from the kernel in 6.17.  Replace with `hardirq_count()`.
Patch: `0002-aic8800_fdrv-replace-in_irq-with-hardirq_count-kernel-6.17.patch`.

### BlueZ vs Android stack

`aic_btusb` defaults to `CONFIG_BLUEDROID=1` (Android char device) even
when `CONFIG_PLATFORM_UBUNTU` is set.  Build with `CONFIG_BLUEDROID=0`
(already fixed upstream in Radxa via `fix-aic_btusb-use-bluez-by-default.patch`).

### Modeswitch fails on reboot on immutable distros

On Bazzite/Silverblue, `/usr/local` → `/var/usrlocal` is not mounted when
udev fires.  A plain `RUN+=` rule fails with "No such file or directory".
Fix: use `TAG+="systemd"` + `ENV{SYSTEMD_WANTS}` to trigger a template
service that runs `After=local-fs.target`.  Also: open `/dev/sgN` with
`O_RDONLY` instead of the block device with `O_RDWR` (CD-ROM media returns
EROFS on write-open).

---

## Upstreaming

| Target | Status | File |
|--------|--------|------|
| `usb_modeswitch` device database | Ready to submit | `upstream/usb_modeswitch/1111:1111` |
| BT `#if 0` fix → BLUEMOON233 | Ready to PR | `patches/0001-*` |
| `in_irq()` fix → BLUEMOON233 | Ready to PR | `patches/0002-*` |
| `BlueZ` default → radxa-pkg (already merged) | Done | — |

---

## Reverse engineering

See [`re/aic8800-upstream-notes.md`](re/aic8800-upstream-notes.md) for full RE notes,
including how the modeswitch command was found via Ghidra headless analysis of
the Windows `AicWifiService.exe` + `Usb_driver.dll` binaries.

Ghidra projects are in [`re/ghidra/`](re/ghidra/).

---

## References

| Repo | Role |
|------|------|
| [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) | Most maintained; BT firmware hotfix at commit `dd2afa18` |
| [BLUEMOON233/AIC8800-Linux-Driver](https://github.com/BLUEMOON233/AIC8800-Linux-Driver) | Kernel 6.17+ compat base (has `#if 0` BT bug) |
| [goecho/aic8800_linux_drvier](https://github.com/goecho/aic8800_linux_drvier) | Alternative (same `#if 0` bug) |
| [usb_modeswitch database](https://www.draisberghof.de/usb_modeswitch/) | Where `upstream/usb_modeswitch/1111:1111` should be submitted |
