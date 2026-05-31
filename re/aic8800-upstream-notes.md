# AIC8800D80 USB WiFi+BT Dongle — Upstream Notes
## Device: LGX/Pandora International 88M80 (USB CD-ROM ID: `1111:1111`)

**Status: WiFi ✅ Bluetooth ✅** (as of 2026-05-30, kernel 6.19.14-ogc5.1.fc44.x86_64, Bazzite 44)

---

## 1. What Was Reverse-Engineered

### Modeswitch Command

Windows installer (`AicWifiService.exe`) triggers modeswitch via `Usb_driver.dll::Set_CS1_0()`,
which sends a 16-byte SCSI vendor command over the Mass Storage bulk endpoint:

```
FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 F2
```

This switches the device from `1111:1111` (CD-ROM/Mass Storage mode) → `a69c:8d80` (AIC firmware-loading mode).

Discovered via Ghidra headless analysis of `AicWifiService.exe` + `Usb_driver.dll` (Windows PE binaries
shipped on the device's virtual CD-ROM). The `Usb_driver.dll` uses `SetupDiGetClassDevsA` +
`CreateFileA` to enumerate USB removable/CDROM drives and sends this command via a storage-class channel.

### USB ID Transitions

```
1111:1111   (CD-ROM, Pandora/LGX, Mass Storage class)
    ↓  SCSI vendor cmd FD..F2  [discovered by RE]
a69c:8d80   (AIC Wlan, firmware-loading mode, vendor-specific class)
    ↓  aic_load_fw.ko  (loads BT patches + WiFi firmware)
a69c:8d81   (AICSemi AIC 8800D80, WiFi+BT mode)
    ↓  aic8800_fdrv.ko / aic_btusb.ko
wlan0 + hci0
```

### Chip Details

- Chip: AIC8800D80, CHIP_REV_U03 (`chip_id=7`, `chip_mcu_id=0`)
- USB BT interfaces: class 0xe0 (Wireless), subclass 0x01, protocol 0x01
- BT address: `68:8F:C9:1E:7C:52`, BR/EDR + LE, secure connections

---

## 2. Driver Bugs Fixed

### A. BT firmware never loaded (`#if 0` in aic_compat_8800d80.c)

**The root cause of BT not working:** the Bluemoon/goecho community drivers wrap the entire
BT patch-loading block in `#if 0`. The Radxa driver has it enabled. The fix is removing two
`#if 0 ... #endif` guards in `aic_compat_8800d80.c`:

1. Outer block: patch table allocation + adid/patch address setup
2. Inner block: actual `fw_adid`, `fw_patch`, `fw_patch_ext0`, `fw_patch_table` upload

The correct firmware loading order (before main firmware, so patches are in RAM at startup):
```
fw_patch_table_8800d80_u02.bin   (1384 bytes)
fw_adid_8800d80_u02.bin          (1708 bytes)
fw_patch_8800d80_u02.bin         (32700 bytes)
fw_patch_8800d80_u02_ext0.bin    (16136 bytes)
fmacfw_8800d80_u02.bin           (358072 bytes — main WiFi+BT firmware)
→ rd_version_val=06090101
→ patch version: Aug 01 2025 11:05:26 - git a26f071
```

**Firmware versions required:** use Radxa's USB firmware (post commit `dd2afa18`).
The older Bluemoon firmware gives `rd_version_val=0` which silently breaks BT.

### B. Kernel 6.17+ build: `in_irq()` removed

```diff
- AICWFDBG(LOGINFO, "...\n", (int)in_irq(), ...
+ AICWFDBG(LOGINFO, "...\n", (int)hardirq_count(), ...
```

File: `aic8800_fdrv/rwnx_rx.c` (one occurrence). Radxa's `fix-linux-6.19-build.patch`
uses `LINUX_VERSION_CODE` guards for a cleaner upstream fix.

### C. BT driver needs BlueZ mode (`CONFIG_BLUEDROID=0`)

`aic_btusb` from Radxa defaults to `CONFIG_BLUEDROID=1` (Android char-device mode).
For Linux/BlueZ, build with `CONFIG_BLUEDROID=0` (`CONFIG_PLATFORM_UBUNTU` triggers this
in Radxa's `fix-aic_btusb-use-bluez-by-default.patch`, already merged upstream in Radxa).

### E. Modeswitch fails on reboot on immutable distros (Bazzite/Silverblue)

**Root cause:** On Bazzite, `/usr/local` is a symlink to `/var/usrlocal`. The `/var` btrfs
subvolume is not mounted when udev fires early in boot. A udev `RUN+=` rule pointing to
`/usr/local/bin/88m80-modeswitch` fails with "No such file or directory" because the
symlink target doesn't exist yet. The device stays in `1111:1111` mode; modules load but
have nothing to probe.

**Fix: defer modeswitch execution via systemd device integration.**

Instead of `RUN+=` in the udev rule, use `TAG+="systemd"` + `ENV{SYSTEMD_WANTS}` to trigger
a template service. The service has `After=local-fs.target`, so systemd waits until `/var`
is mounted before running the script.

`/etc/udev/rules.d/88-88m80-modeswitch.rules`:
```
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTRS{idVendor}=="1111", ATTRS{idProduct}=="1111", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="88m80-modeswitch@%k.service"
```
(`KERNEL=="sd[a-z]"` prevents double-firing on the `sda1` partition.)

`/etc/systemd/system/88m80-modeswitch@.service`:
```ini
[Unit]
Description=AIC8800D80 Modeswitch (%I)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/88m80-modeswitch /dev/%I
```

**Secondary fix: `O_RDWR` on a CD-ROM block device fails with EROFS.**

The modeswitch script was opening `/dev/sda` with `O_RDWR`. When called from a systemd service
(rather than inline from udev), the kernel rejects this on read-only CD-ROM media. Fix: resolve
the block device to its `/dev/sgN` counterpart via sysfs, which accepts `O_RDONLY` for SG_IO:

```python
def find_sg_device(dev):
    name = os.path.basename(dev)
    sg_dir = f'/sys/block/{name}/device/scsi_generic'
    if os.path.isdir(sg_dir):
        entries = os.listdir(sg_dir)
        if entries:
            return f'/dev/{entries[0]}'
    return dev
```

Then open with `os.O_RDONLY | os.O_NONBLOCK` instead of `os.O_RDWR`.

### D. `CONFIG_FOR_IPCAM` — NOT needed

The non-IPC firmware (`fmacfw_8800d80_u02.bin`) works correctly once the BT patch
loading bug is fixed. IPC firmware gave `rd_version_val=0` and broke BT.

---

## 3. What Needs to Be Upstreamed

### A. `usb_modeswitch` — new device entry

File: `/usr/share/usb_modeswitch/1111:1111`

```
# LGX/Pandora International 88M80 — AIC8800D80 USB WiFi+BT dongle
# Modeswitch command discovered by RE of Windows AicWifiService.exe / Usb_driver.dll
# Set_CS1_0() sends 16-byte SCSI vendor command via Mass Storage bulk endpoint
TargetVendor=0xa69c
TargetProduct=0x8d80
MessageContent="fd000000000000000000000000000000f2"
```

### B. Linux kernel AIC8800 driver

Key patches (all relative to Radxa `src/USB/`):

| Patch | File | Description |
|-------|------|-------------|
| Remove `#if 0` guards | `aic_load_fw/aic_compat_8800d80.c` | Enable BT patch loading for D80/U02/U03 |
| `in_irq()` → `in_hardirq()` | `aic8800_fdrv/rwnx_rx.c` | Kernel 6.17+ compat |
| `CONFIG_BLUEDROID=0` for Ubuntu | `aic_btusb/aic_btusb.h` | Use BlueZ, not Android stack |
| Use Radxa USB firmware | `fw/aic8800D80/*.bin` | BT hotfix (commit dd2afa18) |

### D. Modeswitch udev rule for immutable distros

On Bazzite/Silverblue, `usb_modeswitch` or a plain `RUN+=` udev rule won't work at boot
because `/usr/local` (→ `/var/usrlocal`) is not mounted yet. The correct approach is to use
a systemd-triggered template service as described in bug fix E above. This is a general
problem for any distro where the modeswitch script lives outside the early-boot rootfs.

### C. Firmware path on immutable distros (Bazzite/Silverblue)

Driver hardcodes `/lib/firmware/aic8800D80/` (read-only on ostree). Fix: honor
`/var/lib/firmware` in the search path, or use `firmware_class.path`. Workaround:
`insmod aic_load_fw.ko aic_fw_path=/var/lib/firmware/aic8800D80`.

---

## 4. Working Setup (This Machine — Bazzite 44, kernel 6.19.14-ogc5.1.fc44.x86_64)

### Files

| Path | Description |
|------|-------------|
| `/etc/udev/rules.d/88-88m80-modeswitch.rules` | Tags `1111:1111` block device; triggers `88m80-modeswitch@%k.service` via systemd |
| `/etc/systemd/system/88m80-modeswitch@.service` | Template service; runs modeswitch after `local-fs.target` (after `/var` is mounted) |
| `/usr/local/bin/88m80-modeswitch` | Python script: resolves block dev → `/dev/sgN`, sends SCSI FD..F2 via `O_RDONLY` |
| `/etc/udev/rules.d/89-88m80-bt.rules` | Rebinds BT interface to aic_btusb on `a69c:8d81` add |
| `/usr/local/bin/aic8800-bind-bt.sh` | Unbinds btusb, binds aic_btusb |
| `/etc/systemd/system/aic8800-driver.service` | Loads modules at boot (enabled) |
| `/usr/local/bin/aic8800-load-driver.sh` | Module loader script |
| `/usr/local/lib/aic8800/*.ko` | Compiled modules (version-specific) |
| `/var/lib/firmware/aic8800D80/` | Firmware files (Radxa post-dd2afa18) |

### Compiled modules (kernel 6.19.14-ogc5.1.fc44.x86_64)

- `/usr/local/lib/aic8800/aic_load_fw.ko` — Bluemoon base, BT `#if 0` guards removed, `CONFIG_FOR_IPCAM=n`
- `/usr/local/lib/aic8800/aic8800_fdrv.ko` — Bluemoon base, `in_irq()` fix
- `/usr/local/lib/aic8800/aic_btusb.ko` — Radxa source, `CONFIG_BLUEDROID=0`

Source trees:
- `/var/home/lorek/aic8800_bluemoon/` — BLUEMOON233 base with patches applied
- `/var/home/lorek/aic8800/` — Radxa reference repo (aic_btusb source)

### Boot sequence

```
early boot (udev fires, /var NOT yet mounted):
  udev sees 1111:1111 block device (sda)
  → sets TAG="systemd", SYSTEMD_WANTS="88m80-modeswitch@sda.service"
  → does NOT run any script (RUN+= removed; /usr/local not accessible yet)

local-fs.target reached (/var mounted, /usr/local now resolves):
  systemd starts 88m80-modeswitch@sda.service
  → /usr/local/bin/88m80-modeswitch /dev/sda
     → resolves /dev/sda → /dev/sg0 via sysfs
     → opens /dev/sg0 O_RDONLY, sends SCSI FD..F2
     → device re-enumerates: 1111:1111 → a69c:8d80

systemd → aic8800-driver.service (WantedBy=multi-user.target):
  ├─ modprobe cfg80211 bluetooth rfkill
  ├─ insmod aic_load_fw.ko   → probes a69c:8d80, loads BT patches + WiFi fw
  ├─ insmod aic8800_fdrv.ko  → device becomes a69c:8d81 → wlan0
  └─ insmod aic_btusb.ko     → claims BT interfaces → hci0

udev (a69c:8d81 appears) → 89-88m80-bt.rules:
  → aic8800-bind-bt.sh: unbinds btusb, binds aic_btusb
  → bluetoothd initializes hci0 (68:8F:C9:1E:7C:52)
```

### SELinux note (Bazzite)

On Bazzite, `/usr/local` maps to `/var/usrlocal/` (writable overlay). `.ko` files get
`lib_t` label by default; `insmod` from a systemd service requires `modules_object_t`.
The loader script self-heals this with `chcon -t modules_object_t "$KO_DIR"/*.ko` at the top.

---

## 5. Relevant Repos

| Repo | Role |
|------|------|
| [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) | Most maintained; has all needed patches as `debian/patches/`; BT firmware hotfix in commit `dd2afa18` |
| [BLUEMOON233/AIC8800-Linux-Driver](https://github.com/BLUEMOON233/AIC8800-Linux-Driver) | Kernel 6.17+ compat base (still has the `#if 0` BT bug) |
| [goecho/aic8800_linux_drvier](https://github.com/goecho/aic8800_linux_drvier) | Alternative standalone (same `#if 0` bug) |
| [fqrious/aic8800-dkms](https://github.com/fqrious/aic8800-dkms) | DKMS packaging attempt |
