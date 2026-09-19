# Mainline (LTS) kernel on the MU300 — boots to userspace

Mainline **Linux 6.18.52** boots on the ZTE F50 / MU300 (Unisoc UMS9620): all 8 CPUs (4×A55, 4×A76), GICv3, arch
timer, PSCI 1.0, 1.5 GiB RAM, pstore/ramoops, initramfs `/init`, and reboot through the UMP9620 PMIC.

Reference: Unisoc's UMS9620 DT series (LKML, 2023-12-15, "arm64: dts: sprd: Add support for Unisoc's UMS9620", not
merged) describes the same GIC/UART/timer layout; this device is derived from their ums9620-2h10 reference board.

## How it boots
* **Device tree:** the stock vendor DTB in `vendor_boot` is used unchanged. Mainline ignores the vendor-only nodes and
  uses the standard ones (cpus, psci, GIC, timer, memory, reserved-memory, ramoops, ADI). A minimal custom DTB
  (`dts/ums9620-mu300.dts`, installed with `mkvendorboot.py`) was *rejected*: after LK's dtbo merge and fixups the kernel
  hung in `setup_machine_fdt`.
* **Load address:** LK always copies the kernel to 0x80080000 (old text_offset); `wrap-image.py` prepends a branch stub
  so the Image runs from 0x80200000 (2 MiB aligned).
* **Reset:** PSCI SYSTEM_RESET never returns on this firmware. `patches/0001-spi-sprd-adi-add-UMS9620-restart.patch`
  adds the UMS9620/UMP9620 variant to `spi-sprd-adi` (also matching the vendor compatible `sprd,qogirn6pro-adi`) and
  resets through the PMIC software reset, registered above the PSCI handler.
* **Logs:** with a working reset the console survives in ramoops and Android shows it as
  `/sys/fs/pstore/console-ramoops-0` (`tools/collect-logs.sh`).

## Build and test
```sh
docker build -t mu300-mainline-build upstream/
docker volume create mu300-mainline   # unpack linux-6.18.52 into /src of this volume
docker run --rm -v mu300-mainline:/src -v "$PWD/upstream":/work mu300-mainline-build bash /work/build.sh
python3 upstream/wrap-image.py upstream/out/Image upstream/out/Image.lk
python3 boot/build-boot-image.py --kernel upstream/out/Image.lk --init upstream/init-bringup ... --out boot-mainline.img
boot/flash-trial.sh boot-mainline.img      # slot b only, falls back to Android
```

## Debugging without a console
* `stub/pmic-reset.c`: bare-metal PMIC reset used as the kernel entry — proved that LK reaches our code and that the
  PMIC reset works (30 s cycle instead of the ~320 s PM power cut).
* `debug/install-probe.py` (`MU300_PROBE_STAGE=N` for `build.sh`): resets at a chosen boot stage; the cycle time tells
  whether the stage was reached. This located the custom-DTB hang in `setup_machine_fdt`.

## Remaining mainline work
Clocks, pinctrl, power domains, USB 3.1 gadget, eMMC, PCIe, thermal, cpufreq, watchdog, LEDs and Wi-Fi/BT are
working (see the status below). What is still missing:

- ~~**Modem**~~: works since 2026-09-19 - "Modem Alive", AT, SIM, 5G NSA registration and a data context on
  `sipa_eth0`. See "Modem on 6.18" below for what was wrong (shared memory mapped write-back).
- **PM co-processor**: without Android's `modem_control` the board powers off after ~290 s, so the vendor chroot is
  still required.
- **GPU and audio**: not started (`mali_kbase` has never been built for 6.18).
- **Bluetooth**: built as an out-of-tree module, untested on 6.18.

## Modem on 6.18: working (2026-09-19)

The modem comes up on the mainline kernel: "Modem Alive", AT, SIM, radio, **registration on 5G NSA** and a data
context with an address on `sipa_eth0`. Measured on the device:

```
AT         -> OK                                   AT+CFUN?  -> +CFUN: 1
AT+CPIN?   -> +CPIN: READY                         AT+CSQ    -> +CSQ: 37,20
AT+CEREG?  -> +CEREG: 2,1,"C300","00E07F53",13     AT+COPS?  -> +COPS: 0,2,"28602",13
mobile data up on sipa_eth0 (28602)                sipa_eth0  UP  10.x.x.x/8
```

### What was wrong: the shared memory was mapped write-back

The regions the modem and the AP share are reserved **inside** System RAM (no `no-map`), and the vendor 5.4 driver
maps them with `vm_map_ram(pages, count, -1, pgprot_noncached(PAGE_KERNEL))`. Newer kernels dropped the `prot`
argument from `vm_map_ram()`, so the port had switched to `memremap(..., MEMREMAP_WC | MEMREMAP_WB)`, which falls
back to **write-back** whenever write-combine is not available - and it never is for a linear-mapped region.

The modem does not snoop the AP's caches, so everything the AP wrote stayed invisible to it. The symptom was
subtle rather than fatal: the CP started, asked for its NV data, and the NV server logged `fail SIZE` on the
second packet, wrote three chunks and stalled; `modem_control` then gave up with `wait modem alive timeout` and
`g_modem_state = 8`. `ioremap_wc()` is not an answer either - the kernel refuses it for addresses inside System
RAM (`WARNING at arch/arm64/mm/ioremap.c:27`), which is exactly what happened when it was tried.

`vmap(pages, count, VM_MAP, prot)` still takes a pgprot, so `smem.c` now builds the page array like the vendor
driver and maps the regions non-cached again, keeping `memremap()` only for regions that have no `struct page`
(real `no-map`) and for the ones the vendor code wants cached.

Before and after, from the same logs:

| | write-back (before) | non-cached (after) |
|---|---|---|
| `fail SIZE` | 1 | 0 |
| NV packets served (`writeData`) | 3 | runs to completion |
| "Modem Alive" | never | yes |

### Bring-up

`tools/mu300-modem-ml-load` loads 25 modules (no `sipa-dele`, see its comment). `cp_diskserver` is started first,
`modem_control` about 8 s later. "Modem Alive" arrives within a minute, and `mu300-atd` then serves AT normally -
15 commands in a row with no reopen needed.

Still open: `mali_kbase` has never been built for 6.18, so there is no GPU, and audio is untouched.

## Status (2026-09-17): OpenWrt runs on 6.18.52

The installed OpenWrt 25.12.5 boots on the mainline kernel through the normal `boot/init`
(multi-OS switch_root): SSH, LuCI, `br-lan` over the USB 3.1 gadget, fw4/nftables, zram.

Fixes needed on top of the port:

- `sdhci-sprd`: UMS9620 has the r11p3 controller; the vendor driver programs DLL phase `0x2`
  (mainline `0x3`). With `0x3` reads work in HS400ES but every write fails with data CRC errors.
- `sdhci-sprd`: only the non-removable eMMC is probed (the SD slot is unpopulated and floods the log).
- UMP9620 PMIC watchdog, armed by LK for 300 s, is disabled by `ump9620-pmic-wdt-off`.
- Userspace config: cgroups/namespaces/seccomp, bridge, nftables, IPv6, zram.
- Thermal: vendor `sprd_thermal_r5p0` (19 on-die zones) with calibration from the UMS9620 eFuse; the eFuse
  provider is built read-only.
- cpufreq: vendor `sprd_sip_svc` + `sprd-cpufreq-v2`; ATF does the DVFS, the kernel asks through SIP SMC calls
  (3 policies: 4 little / 3 mid / 1 big, schedutil). PSCI cpuidle (WFI, core sleep, cluster power-down).
  Idle temperature dropped from ~54 C to ~48 C.
- The stock DT has trip points only on the vendor virtual zone, so `/opt/mu300/bin/thermal-guard` caps cpufreq
  above 85 C and powers off above 105 C on kernels without SoC trip points.

- Watchdog: the UMP9620 PMIC watchdog that LK arms is taken over (`ump9620-pmic-wdt`), 60 s, pinged by the
  core until procd/systemd opens it; a hard hang resets the board back to Android.
- LEDs: UMP9620 RGB status LEDs (vendor `sc27xx-bltc`).
- PCIe: vendor `pcie-sprd` ported to the 6.18 DWC host API. `num-vectors` from the DT is honoured, the
  Marlin3 driver needs a contiguous block of 32 MSIs.
- Wi-Fi/BT (SC2355 Marlin3): `modules/` holds the vendor `wcn_bsp`, `sprd_wlan_combo` (SC2355 PCIe only) and
  `sprdbt_tty` ported to 6.18 as out-of-tree modules (`build-modules.sh`; `tools/port54.py` does the mechanical
  5.4 API changes, `wcn_bsp/kinclude/mu300_compat.h` the rest). On OpenWrt the chip boots its firmware and the
  5 GHz VHT80 AP beacons. The factory Wi-Fi MAC is read from `androidboot.wifimac` in `/chosen/bootargs`.
  The WCN modules cannot be unloaded and reloaded (same as on 5.4).

Not yet on mainline: modem (sipc/sipa/modem loader), GPU, audio; Bluetooth is built but untested.
