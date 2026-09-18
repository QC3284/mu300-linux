# Running other distributions

The boot path does not care which distribution it starts. The initramfs mounts the ext4 filesystem in the free eMMC
area, reads `/.mu300/boot-os`, and `switch_root`s into the directory named there. So a system is just a directory
with a root filesystem in it, and `mu300-os <name>` picks the one to boot next.

What a distribution has to bring:

* **arm64 (aarch64) userspace.**
* **It must work on Linux 5.4.** This is the limit in practice: the kernel is ZTE's vendor 5.4, and the newest
  userspaces have started to depend on newer kernels. Ubuntu 26.04 was dropped for exactly this reason — its `tar`
  resolves every path with `openat2` (Linux 5.6) and fails on this device.
* **Nothing else.** Drivers, firmware and the Android vendor chroot come from this repository's overlay, which is
  copied into every image.

## Ready to build here

| Distribution | Build | Notes |
|---|---|---|
| Ubuntu 24.04 LTS | `rootfs/` (default) | the tested default, systemd 255 |
| OpenWrt 25.12 | `openwrt/build-rootfs.sh` | router use, LuCI, ~140 MiB RAM |
| ImmortalWrt 25.12 | `MU300_FLAVOUR=immortalwrt openwrt/build-rootfs.sh` | OpenWrt fork with more drivers and LuCI apps |
| Arch Linux ARM | `arch/build-rootfs.sh` | rolling, 258 MiB image / 922 MiB installed; built, not yet booted on hardware |
| Debian 13 | `docker build --build-arg BASE=debian:13 -t mu300-debian:13 rootfs/` then `rootfs/assemble.sh` | same package names as Ubuntu |
| Kali Linux | `docker build --build-arg BASE=kalilinux/kali-rolling -t mu300-kali rootfs/` then `rootfs/assemble.sh` | see below |

The Arch build removes the `linux-aarch64` kernel and `linux-firmware` packages that the generic Arch ARM image
ships (about 1.5 GB): this device boots the vendor kernel from the boot image and takes its firmware from Android.
`pacman`'s Landlock sandbox is disabled for the build only, because it cannot work inside the build container.

## Kali Linux, honestly

Kali is Debian, so it installs and runs exactly like the Debian image, with its tools available through `apt`. What
it cannot do on this device:

* **No monitor mode or packet injection.** The Wi-Fi chip is a Unisoc SC2355 with a vendor driver that offers
  station and access-point mode only. `airmon-ng` has nothing to switch, so the classic Wi-Fi attacks are out.
* **No external Wi-Fi adapter**, at least not yet: the USB-C port runs as a *gadget* (the device pretends to be a
  network card for your computer). Host mode would be needed to attach an adapter, and that is untested here.
* **No screen.** Everything is over SSH; Kali's desktop tooling is pointless on this hardware.

What is left is still useful: a pocket-sized box with its own 5G modem that can run `nmap`, `sqlmap`, `metasploit`,
proxies and scanners over the mobile connection or the Wi-Fi it is connected to.

## What does not fit

* **Anything that needs its own kernel** (Fedora IoT, postmarketOS images, Home Assistant OS): they ship kernels
  built for other devices, and this one only boots the vendor 5.4 kernel from the boot image.
* **Distributions whose userspace requires a newer kernel**: Ubuntu 26.04 and later, and eventually any rolling
  distribution. Arch works today; a future `glibc` or `systemd` may end that, which is why it is the "fun" option
  and not the default.
* **x86 anything.**

## Installing a distribution you built

The installer knows `ubuntu` and `openwrt` by name. For anything else, unpack the tarball next to them and select
it (from Android, with the Linux filesystem mounted as in `tools/android-mount-mu300root.sh`):

```sh
mkdir -p /data/local/tmp/mu300root/arch
tar -xzpf mu300-arch-rootfs.tar.gz -C /data/local/tmp/mu300root/arch
echo arch > /data/local/tmp/mu300root/.mu300/boot-os
```

From a running Linux on the device, the same thing under `/mnt/mu300-disk/`, then `mu300-os arch` and reboot.
If it does not boot, the bootloader falls back to Android by itself, and `mu300-os ubuntu` brings the old system
back.
