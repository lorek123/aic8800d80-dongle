# AIC8800D80 USB WiFi+BT Dongle — RE Notes and Bazzite Integration

RE documentation and immutable-distro (Bazzite / Silverblue) setup for the
**LGX/Pandora International 88M80** USB WiFi+BT dongle (chip: AIC8800D80,
CD-ROM mode `1111:1111`, active mode `a69c:8d81`).

**Status: WiFi ✅ Bluetooth ✅** (kernel 6.19, Bazzite 44 / immutable Fedora)

> **Other repos you should know about:**
> [olamellberg/AIC8800D80](https://github.com/olamellberg/AIC8800D80) — clean installer for standard distros
> [shenmintao/aic8800d80](https://github.com/shenmintao/aic8800d80) — comprehensive DKMS packaging, Bazzite RPM spec

---

## What this repo adds

Two things not covered elsewhere:

**1. Reverse engineering trail** — The modeswitch SCSI command (`FD..F2`) and
the full USB ID transition sequence were found by Ghidra analysis of the
Windows `AicWifiService.exe` / `Usb_driver.dll` binaries shipped on the
device's virtual CD-ROM.  See [`re/`](re/) for the complete notes and Ghidra
projects.  Other repos list the command; this is where the command came from.

**2. Bazzite / Silverblue boot integration** — On ostree-based immutable
distros, `/usr/local` is a symlink into `/var` which is **not mounted when
udev fires**.  A standard `RUN+=` modeswitch rule silently fails at every
boot.  The fix is a systemd template service (`After=local-fs.target`) that
udev schedules but does not run directly.  No RPM build required — just three
files.  See [Modeswitch on immutable distros](#modeswitch-on-immutable-distros).

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

`Usb_driver.dll::Set_CS1_0()` sends a 16-byte SCSI vendor command via the
Mass Storage bulk endpoint (see [`re/`](re/) for how this was found):

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

For `usb_modeswitch`, this must be wrapped in a 31-byte USB Mass Storage CBW
(see `upstream/usb_modeswitch/1111:1111`).  The Python script in `modeswitch/`
uses `SG_IO` directly so the kernel handles CBW framing automatically.

### Modeswitch on standard distros

For standard (mutable) distros, `usb_modeswitch` with the entry in
`upstream/usb_modeswitch/1111:1111` is the simplest path.  See also
[olamellberg/AIC8800D80](https://github.com/olamellberg/AIC8800D80) for a
fully automated installer.

### Modeswitch on immutable distros

On Bazzite/Silverblue, `/usr/local` → `/var/usrlocal` is **not mounted when
udev fires** early in boot, so `usb_modeswitch` or any `RUN+=` rule pointing
to `/usr/local/bin/` fails silently.  The device stays in `1111:1111` mode,
modules load but find nothing to probe, and there is no error in the log.

**Fix:** use `TAG+="systemd"` + `ENV{SYSTEMD_WANTS}` so that udev schedules
a template service instead of running a script directly.  The service has
`After=local-fs.target`, so systemd waits until `/var` is mounted.

```bash
# Install the Python modeswitch script
sudo install -m 755 modeswitch/88m80-modeswitch /usr/local/bin/

# Install udev rule + systemd service
sudo install -m 644 modeswitch/88-88m80-modeswitch.rules /etc/udev/rules.d/
sudo install -m 644 modeswitch/88m80-modeswitch@.service /etc/systemd/system/
sudo udevadm control --reload-rules
```

The script resolves the block device to its `/dev/sgN` counterpart via sysfs
and opens it `O_RDONLY` — a direct `O_RDWR` open on CD-ROM block media fails
with `EROFS` when called from a service rather than inline from udev.

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
| BT `#if 0` fix → BLUEMOON233 | PR open | `patches/0001-*` |
| `in_irq()` fix → BLUEMOON233 | PR open | `patches/0002-*` |
| `BlueZ` default → radxa-pkg | Already merged | — |

---

## Reverse engineering

See [`re/aic8800-upstream-notes.md`](re/aic8800-upstream-notes.md) for full RE notes:
how `Set_CS1_0()` was found in `Usb_driver.dll` via Ghidra headless analysis,
how the USB ID transitions were traced, what the BT firmware loading bug
actually is and why it's silent, and the boot-timing root cause on ostree.

Ghidra projects (analyzed `Usb_driver.dll` and `AicWifiService.exe`) are in
[`re/ghidra/`](re/ghidra/).

---

## References

| Repo | Role |
|------|------|
| [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) | Most maintained; all patches as `debian/patches/`; BT firmware hotfix at `dd2afa18` |
| [BLUEMOON233/AIC8800-Linux-Driver](https://github.com/BLUEMOON233/AIC8800-Linux-Driver) | Community base driver (still has `#if 0` BT bug as of this writing) |
| [goecho/aic8800_linux_drvier](https://github.com/goecho/aic8800_linux_drvier) | Alternative community base (same `#if 0` bug) |
| [olamellberg/AIC8800D80](https://github.com/olamellberg/AIC8800D80) | Standard-distro installer for this exact device |
| [shenmintao/aic8800d80](https://github.com/shenmintao/aic8800d80) | DKMS packaging + Bazzite RPM spec |
| [usb_modeswitch database](https://www.draisberghof.de/usb_modeswitch/) | Where `upstream/usb_modeswitch/1111:1111` should be submitted |
