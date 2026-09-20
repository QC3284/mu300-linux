# Findings: running Linux on the ZTE F50 / MU300 (Unisoc T760)

Everything below was verified on a ZTE F50 (hardware MU300, firmware `MU300_ZYV1.0.0B09`,
Android 13, stock kernel `5.4.254-android12-9-g9c6342244991`) during September 2026.
Each item lists the symptom, the root cause and the fix, so it can be reused for other
UMS9620 devices (for example the ZTE U30 Air).

## Hardware and firmware facts

| Item | Value |
|---|---|
| SoC | Unisoc T760 (UMS9620, "qogirn6pro"), board `ums9620_2h10_feimao` |
| RAM | 2 GiB (about 1.4 GiB visible to Linux, the rest is reserved for modem/TEE) |
| Storage | eMMC, about 58.25 GiB (122159104 sectors) |
| PMIC | UMP9620 (+ UMP9621), charger IC bq2560x/sgm41513, fuel gauge sc27xx-fgu |
| Wi-Fi/BT | SC2355 "Marlin3" on PCIe, firmware `MARLIN3_20A_RLS2_W24.45.4` |
| USB | DWC3 (`25100000.dwc3`) + MUSB (`musb-hdrc.1.auto`), Type-C on the PMIC |
| Bootloader | Unisoc LK ("sprdlk"), Trusty TEE, A/B slots |
| Boot images | boot and vendor_boot are Android header v4, page 4096, LZ4 legacy ramdisks |

## Boot chain and safe testing

### 1. Slot b one-shot trial (never touch boot_a)
* Linux is written to **boot_b** only, and the 32-byte AOSP `bootloader_control` block at
  offset `0x800` of `misc` is set so that slot b has the highest priority.
* **Unisoc LK treats `tries_remaining == 1 && successful_boot == 0` as an already failed boot**
  (`ANDROID: slot 1 booted fail, rolling back spl and reboot into normal`). A one-shot trial therefore
  needs `tries_remaining = 2`: LK decrements it to 1 and boots slot b; if that boot fails, the next boot
  rolls back to slot a.
* Linux `init` writes the original slot-a block back to `misc` as one of its first steps, so any later
  reboot returns to Android.
* The `uboot_log` partition contains LK's ring log. It is the best source for "which slot was chosen" and
  "why did it reset" (`rst_mode`, `charge first poweron reset`, watchdog flags).

### 2. Boot ramdisk must be LZ4 legacy
* Symptom: `RAMDISK: lz4 image found at block 0`, `RAMDISK: incomplete write (-28 != 8388608)`, then
  `VFS: Unable to mount root fs on unknown-block(1,0)`.
* Cause: vendor_boot's ramdisk is LZ4 legacy; a gzip boot ramdisk appended to it is not unpacked as an
  initramfs by this 5.4 kernel, which then falls back to the legacy `/dev/ram0` image path.
* Fix: compress the boot ramdisk with `lz4 -l`. Also add a `dev/console` node to the cpio.

### 3. Logs without a serial console
* The stock cmdline has `loglevel=1`, so nothing reaches `console-ramoops`.
* pstore only survives a warm reset. Most failures on this device end in a power cut, so init also
  persists its stage list and `dmesg` into unused space inside **boot_b at 48 MiB (8 MiB)**; it is read
  back from Android.
* A USB CDC-ACM function (`acm.GS0`) next to ECM gives a login console on the host
  (`/dev/cu.usbmodem*` on macOS) that works even when networking does not.

## Hardware bring-up with the vendor modules

### 4. USB gadget dependency chain
The UDC only appears when the whole chain probes, in this order:
`extcon-usb-gpio` (the PHY node references `extcon-gpio`) → PHYs → `sc27xx_adc` → `sprd_battery_info`
→ `sprd-charger-manager` → `sc27xx_fuel_gauge` → `bq2560x-charger` (provides the `otg-vbus` regulator used as
`vbus-supply` by DWC3 and MUSB) → `dwc3-sprd` / `musb_sprd`.
* **`sc27xx_adc` must be loaded before the fuel gauge.** The vendor `sc27xx-fgu` driver returns a hard error
  (not `-EPROBE_DEFER`) when its IIO channel is missing and is never probed again.
* The exact working order of the 86 modules is in `boot/module-order.txt`.

### 5. The ~290 s power cut (PM co-processor watchdog)
* Symptom: Linux runs normally, then the device loses power about 290 s after boot. LK shows
  `charge first poweron reset`, not a watchdog reset.
* Cause: the PM co-processor (CM4, `pm_sys`) runs its own watchdog. `sprd_pmic_wdt` disarms it by sending
  `watchdog rstoff` over an SIPC sbuf channel, but that channel only becomes ready after Android's
  `modem_control` reloads `pm_sys` (and the modem) through Trusty (`kernelbootcp` TA).
* Fix: run Android's own `/vendor/bin/modem_control` in a chroot with Android's bionic linker and
  libraries. Requirements that were each discovered by failure:
  1. Copy `/dev/__properties__` from a running Android so property reads work.
  2. Create `/dev/block/by-name` links and apply Android's node ownership (`ueventd.rc` plus `chown`/`chmod`
     from vendor `init*.rc`), because `modem_control` drops to uid `system` (1000).
  3. Bind-mount a copy of `/proc/cmdline` with `androidboot.slot_suffix=_a` so it loads the `_a` modem images
     (LK passes `_b` when booting the trial slot).
  4. **Exec the binary directly.** `sprd_modem_loader` rejects every ioctl/write unless `current->comm` is
     exactly `modem_control` (`drivers/unisoc_platform/modem_loader`); running it as
     `linker64 /vendor/bin/modem_control` makes the task name `linker64`.
  5. Provide a sink for liblog (`tools/logdw`, listens on `/dev/socket/logdw`), otherwise the daemon's logs vanish.
* Result: `kbc_verify_all_avb2() ret = 0`, `SEC_KBC_START_CP() ret = 0`,
  `sprd-pmic-wdt: sbuf ready for pmic wdt init!`, `Modem Alive`, and no more power cut.

### 6. Load average of about 12 is not CPU usage
Vendor kernel threads (`sprd-rotation/N`, `sipa-*`, `slog`) wait in `D` state; Linux counts them in the load
average. `top` shows about 98 % idle.

## Custom kernel

### 7. Matching source
* The ZTE U30 Air kernel (`github.com/Enceka/android_kernel_zte_ums9620_mifi_u30air`, "downloaded from ZTE
  opensource") is exactly 5.4.254, covers 137 of the 150 F50 vendor modules and all but one derived config
  symbol of the F50 stock config.
* Missing from that tree: camera/display/GPU/touch modules (not used on this device) and the Wi-Fi driver
  `sprd_wlan_combo`, which is taken from the realme C51/C53 AndroidT kernel_modules drop.
* An older Unisoc 5.4.147 tree lacks the whole qogirn6pro USB stack and is not usable.

### 8. Build notes
* Full LTO needs more than 8 GiB in the linker step; ThinLTO keeps CFI and links fine.
* Stock config + `kernel/mu300-linux.fragment` adds devtmpfs, fhandle, autofs, SysV IPC, namespaces, nftables,
  btrfs/xfs/squashfs, NFS/CIFS, USB serial/modem/audio host drivers, crypto user API, CDC-ACM gadget, and removes
  `STATIC_USERMODEHELPER` and forced module signatures.
* All vendor modules must be rebuilt from the same tree (symbol CRCs change).

## Root filesystem on free eMMC space

### 9. Unused space after userdata
* `userdata` is 20 GiB and ends at sector 54218752; the GPT's last usable LBA is 122155007 and the backup GPT
  is at the very end. About **32.4 GiB between them belongs to no partition** and read back as zeros.
* The rootfs is an ext4 filesystem (`mu300root`) at byte offset `27762098176` (sector 54222848), 32.39 GiB,
  accessed through a loop device with an offset. **The GPT, userdata and all Android partitions are unchanged.**
* `userdata` uses metadata encryption (`dm-default-key`, `inlinecrypt`), so it cannot be shrunk or shared.

### 9b. There is no second home for the rootfs
Asked for often, because a smaller eMMC variant leaves less free space behind `userdata`. Measured on the device:

* **An image file inside `userdata` cannot work.** Metadata encryption covers the whole partition, not just file
  contents: `mmcblk0p75` reads as ciphertext from Linux - 4079 of the first 4096 bytes are non-zero, no ext4 magic
  at `0x438` (`2d81`), no f2fs magic at `0x400` (`58931da1`). The same `dd` on our own region returns `53ef` and
  the label `mu300root`, so this is the partition and not the reader. The key lives in keymaster and `metadata`
  and Android unwraps it at boot, so a file created from Android is unreadable from Linux whatever we do to it.
* **`blackbox` (500 MiB) and `fulldumpdb` (2 GiB) are not spare.** They look unused, but sampling shows
  `fulldumpdb` non-zero in 16 of 16 samples (it starts with a `note` record) and `blackbox` in 1 of 16: the
  firmware writes crash dumps there.
* So the gap after `userdata` is all there is. The installer no longer demands 4 GiB of it: the installed systems
  measure ~320 MiB (OpenWrt) and ~580 MiB (Ubuntu) and an update keeps the previous one as `<os>.old`, so it asks
  for 800 MiB, 1.6 GiB or 2.4 GiB depending on the choice, and prints the eMMC size and the end of the last
  partition, which identifies the variant when it still does not fit.

### 10. Mounting gotchas
* busybox `mount -o loop,offset=` only creates a loop for regular files; for a block device the options go to
  ext4 and fail with `EINVAL`. Use `losetup -o` and verify `/sys/block/loopN/loop/offset`.
* Android's `losetup -f` can return a loop index whose node does not exist yet; allocate, wait for the node and
  refuse to attach the same offset twice (two loops mounting one ext4 corrupted it once).
* Toybox `od` on 64 MiB is extremely slow; never interrupt a safety check, an interrupted pipeline "passed" once.

## Ubuntu on kernel 5.4

The root filesystem moved from Ubuntu 26.04 to 24.04 LTS: 26.04's userland starts to depend on syscalls newer than
5.4 (below), 24.04 is supported until 2029 and runs on 5.4 without workarounds.

### 11. systemd 259 works on 5.4
5.4 is systemd's minimum baseline; the system boots to `running` with the `old-kernel` taint.

### 12. USB Ethernet must be up before the host activates ECM
* Symptom: macOS shows the "MU300 Linux USB Ethernet" interface as `inactive` forever, no DHCP, although on the
  device `usb0` is UP with carrier.
* Cause: `usb0` was only brought up by a systemd unit a few seconds after the UDC was bound. f_ecm reports the link
  in its first CONNECT notification and macOS' `AppleUserECM` does not pick up a later "connected" notification.
* Fix: `ifconfig usb0 up` immediately after binding the UDC in the initramfs.

### 13. Userland needing newer syscalls
* Ubuntu 26.04's GNU `tar` (1.35+dfsg-4ubuntu0.4) fails with `Cannot stat: Function not implemented` for every
  path, creating and extracting: it resolves paths with `openat2` (Linux 5.6) and has no fallback. 24.04's tar does
  not use `openat2`.
* `ssh.service` is socket-activated (24.04 and 26.04); enable `ssh.socket`, not only `ssh.service`.
* Extracting an archive that contains a `lib/` directory over Ubuntu replaces the `/lib -> usr/lib` symlink with a
  directory (systemd then disappears). Always ship files under `usr/lib/...`.
* `docker export` leaves `/etc/hostname` empty.

### 13b. One reader at a time on the modem's AT tty, and reopen it after a modem restart
`/dev/stty_nr*` are SIPC channels, not real serial ports, and the data goes to **one** reader. While a process
holds the channel, a second one that opens the device reads nothing - it is not broken, it is simply not the owner.

Both of the things this section has claimed over time are true, of different situations, and telling the two apart
is the whole problem:

* A descriptor that was open **across a modem restart** (`AT+SFUN=4`, or a CP crash) refers to a channel that no
  longer exists, so it reads nothing - and because it still occupies the device, every other opener is shut out
  too, which is what made it look permanent. Closing it and opening the device again fixes *that* case
  immediately. Measured: with the daemon holding a stale descriptor, all six channels are silent; with the daemon
  stopped, all six answer `OK` at once.
* **Closing the descriptor while the modem is running does the opposite: the channel never answers again.**
  Measured on 5.4, with `AT+CGACT?` answering normally minutes earlier: `mu300-atd` was killed and started again -
  one close, one open, nothing else - and from then on `/dev/stty_nr1` accepted writes and returned nothing, for
  the remaining forty minutes of that boot. Everything tried against it failed: opening it raw with no daemon at
  all, opening `nr0`-`nr5` together, draining `nr0`, and `/etc/init.d/mu300-vendor restart` - `modem_control`
  re-attaches without reloading the modem (the kernel logs `modem_control has get lock 0`, and no boot follows).
  Only a reboot brings it back. The modem is fine throughout: `nr0` keeps delivering `+SIND` and `+ECIND`, and
  debugfs `modem` still reports `run_state: 1`.

A reopen is therefore the only cure for one case and the cause of the other, so the daemon needs evidence before
it decides, and `nr0` is that evidence: the modem's unsolicited output never stops while it is running, so a `nr0`
that is still producing lines means the modem is alive and this descriptor is fine - whatever else is wrong,
closing it can only make things worse.

Three rules follow, and `mu300-atd` implements all three:

* **Exactly one owner.** The daemon holds the tty and serves one command at a time through a pair of fifos in
  `/run/mu300-at`; `mu300-at "AT+CSQ"` asks it, and `mobile-data` uses it automatically when it is running. Nothing
  else may open the device - including `stty -F`, which is an open and a close of its own.
* **Drain `nr0`.** It is read continuously into a capped log under `/run/mu300-at/urc/`, the way Android's RIL
  holds all six channels open. It is not a cure for a silent channel - that was tried - but registration and PDP
  changes are announced there and nowhere else, and `stty_nr0.log` is what the reopen rule below is built on.
  `nr2`-`nr5` are left alone by default (`MU300_AT_URC_CHANNELS` takes them): a drainer owns its channel as
  completely as the daemon owns `nr1`, and measured, those four say nothing at all.
* **Reopen only when the modem is really gone.** Five unanswered commands, at most one reopen every five minutes,
  and only when `stty_nr0.log` has been quiet for 240 s as well. The earlier rule - reopen after two or three
  unanswered commands - traded a working modem for a dead one on any device busy enough to miss a few replies.

"Exactly one owner" has to be enforced, not assumed. On the mainline kernel the modem kept going quiet a few
minutes after every boot, and it was neither the channel nor the modem: **a second `mu300-atd` had been started**
(procd respawning it, a service started twice). Two daemons read the same `/dev/stty_nr1` and each gets part of
every reply, and the newcomer removes and recreates the command fifo under the one already running, so every
command returns empty. What follows looks exactly like a lost network - the watchdog sees no context, takes the
interface down, netifd tears `wan` down and rebuilds it for ever - while the modem is untouched: stopping every
daemon and starting a single one answered `+CSQ: 43,24` with `+CGACT:1,1` still active. `mu300-atd` now takes
`/run/mu300-at/lock` before it opens the tty or creates the fifo; a second instance waits there instead of
exiting, so a spare is always ready to take over if the owner is killed.

The lock alone was not enough, because `mobile-data` could still walk past it. Its `at()` asks the daemon when
`/run/mu300-at/cmd` exists and opens `/dev/stty_nr1` itself when it does not - and "no fifo" is not the same as
"no daemon". Remove `/run/mu300-at` under a running `mu300-atd` (a stale lock cleaned up by hand, a `tmpfiles`
sweep) and the daemon keeps its descriptor while the fifo is gone, so every `mobile-data` call takes the direct
path and becomes a second reader on a channel that hands each line to exactly one of them. Found on the device:
`mu300-at` reporting "the daemon is not reading commands" while `/proc/*/fd` showed `mu300-atd` *and*
`mobile-data watch` both holding `/dev/stty_nr1`. `mobile-data` now checks `/run/mu300-at/lock/pid` before it
opens anything: a live `mu300-atd` behind that pid means "refuse and say so", and otherwise it takes the same
lock for the length of the command. `tty_setup` obeys the same check, since `stty -F` is an open and a close.

Also make sure only one bring-up runs at a time: `mobile-data up` from the service and from the watchdog used to
run concurrently, and the two of them take the channel lock away from each other for every single AT command, so
neither finishes. `mobile-data` now holds `/run/mu300-mobile-data-up.lock` while it works, `down()` leaves the
context alone while a bring-up owns the channel, and only one watchdog runs.

Verified on 5.4 after these changes: a full `down`/`up` cycle followed by AT queries, and 12 queries over two
minutes with the watchdog polling at the same time - all answered, no reopen needed.

A lock for this has to avoid one trap: **ash and dash run an `EXIT` trap when a subshell exits**, and the daemon
runs a subshell per command (`reply=$(collect ...)`). A `trap 'rm -rf $LOCK' EXIT` therefore deleted the lock a
second after taking it, and the next daemon walked straight in - the very failure the lock was meant to stop, now
happening every few seconds. Clean up on `INT`/`TERM` only, and only when the pid in the lock is still ours.

### 13b-2. The modem stops answering on Linux - and it is not the mainline port (open)
**Measured on both kernels and on stock Android, in that order, and the answer is not what it looked like.** The
modem stops talking to the AP partway through every Linux boot and never comes back without a reboot:

| System | First AT reply | Then | `sipa_eth0` |
|---|---|---|---|
| mainline 6.18.52 | 67 s | silent 22 s later | address, `rx=0` |
| vendor 5.4.254 | 60 s | silent 17 s later | address, `rx=0` |
| stock Android 13 | - | keeps working | address, **`rx=104`** |

So this is **not a regression in the mainline port**: the vendor kernel the device shipped with fails the same way
on the same day, and Android on the same hardware, SIM and carrier passes traffic. What is missing is on our side
of userspace, and it is missing on both kernels. Android runs a full modem stack (RIL, `phoneserver`/`atcmdsrv`,
`slogmodem`, the IMS bridge); we run `modem_control`, `cp_diskserver` and `refnotify` and nothing else - and
`refnotify` cannot even open `/dev/stime_ch` (ENODEV, the time-sync channel), on both kernels. The 5.4 module list
also loads `sipa_usb`, `sprd_pamu3` and `sfp_core`, none of which the mainline build has, though 5.4 shows `rx=0`
with them, so they are not sufficient by themselves.

The rest of this section is what was measured while the failure was still thought to be mainline's. Typical run: `+CSQ: 44,26` at 67 s, nothing at 89 s. What dies is the CP's side of SIPC - the outbox
(CP -> AP) mailbox interrupt stops counting, the modem's own log stops at the same moment, and after the mailbox
fix (13e) the AP's messages still go out and are simply never answered. Restarting the vendor daemons does not
recover it; `modem_control` reloading the modem does not either.

The timing is not fixed: measured deaths 24 s to 60 s after the first successful command (53 s, 87 s, 90 s, 91 s,
109 s of uptime), and not a fixed number of commands either - ten in a fast loop, four at one command every ten
seconds.

Ruled out by measurement, so that nobody spends another evening on them:

* **Our own boot recorder.** It did write 8 MiB to the eMMC every five seconds and that is worth fixing on its own
  (§ below), but with it disabled the channel still died.
* **A cached alias of the modem's shared memory.** The vendor device tree marks these reservations without
  `no-map` (only `rebootescrow` has it), so the 5.4 kernel maps them exactly the same way.
* **The modem power manager.** `sprd_mpm_init_resource_ops()` is never called in the 5.4 tree either, so the NULL
  request/release callbacks are normal for this SoC.
* **The data attach.** With `wan` disabled and no `AT+CGDATA` at all, the channel dies just the same.
* **Two daemons on the channel** (real bug, fixed in 13b) and **the modem log ring filling** (real, 257 KB were
  sitting unread, drained now) - neither stops the failure.
* **A full software mailbox queue** (real bug, fixed in 13e) - the AP can send again, and the modem still goes
  quiet.

Also ruled out by the same differential: **our own services**. With `mu300-atd` and `mobile-data` killed and a
single shell holding the tty, the channel still went silent (132 s instead of ~90 s).

The next step is therefore not a kernel one: find what the CP expects from the AP that Android provides and we do
not - the time-sync channel `refnotify` cannot open is the most concrete lead, followed by running more of the
vendor modem userspace in the chroot the way `modem_control` already is.

### 13f. The data call completes and still nothing arrives (open)
Measured step by step on 5.4 with the release userspace, so none of it is a mainline or a script regression:

* `AT+CFUN?` is **0 at boot** - the radio is off until `mobile-data` turns it on. Any experiment that stubs
  `mobile-data` out is testing a device with no radio, which is why "the AT channel survives when nothing
  attaches" proved less than it looked.
* With the radio on, the bring-up is textbook: `+CEREG: 2,1` (registered), `AT+CGACT=1,1` returns `^ORIG: 1,2 OK`,
  `AT+CGACT?` reports `+CGACT:1,1`, `AT+CGCONTRDP=1` hands back an address, a netmask and both DNS servers, and
  `AT+CGDATA="M-ETHER",1` answers `^ORIG: 1,2` and then `CONNECT`.
* Configure `sipa_eth0` with exactly that address and route, and **`rx_packets` stays at 0**. Not one downlink
  packet, on either kernel, while stock Android on the same device, SIM and carrier shows `rx=104`.
* `cid 11` is the IMS context (`ims.MNC002.MCC286.GPRS`), not a second internet bearer, and no other `sipa_ethN`
  receives anything either.

**`AT+CGDATA` needs a long timeout.** It answers `^ORIG` first and `CONNECT` ten to twenty seconds later. The
eight-second budget `mobile-data` used meant the reply landed after we had given up, so the next command read
*that* instead of its own answer - which is most of what "the AT channel dies after the attach" really was.
Raised to 45 s.

What is left is the IPA receive path itself. Two differences from Android are recorded but neither is proven:
its RIL defines the context as `AT+CGDCONT=<cid>,"IP",<apn>,"",0,0,0,0,1` (IPv4 only, with the vendor's extra
parameters) where we ask for `IPV4V6`; and its `SIPA_RM_RES_CONS_WWAN_DL` is granted while ours is never
requested - though in `sipa_nic.c` that consumer belongs to PCIe-source nics, and this modem is on-chip.

**Read the IPA state before theorising - `/sys/kernel/debug/sipa/` answers most of it**, and two of its fields
are easy to misread:

* `nic`: `suspend_stage`, `rc` (resumes), `sc` (suspends), `is_bypass`, then one line per allocated nic. A fresh
  boot that has sent nothing shows `suspend_stage = 0x3f rc = 0` and that is **correct, not a fault**: the driver
  sets `suspend_stage = SIPA_SUSPEND_MASK` in probe (`sipa_core.c`) and the hardware is woken lazily, by the
  first transmit, through `sipa_nic_rm_res_request()`. Likewise `open = 0` on a nic line means `NIC_OPEN`, since
  that enum starts at 0 (`sipa_priv.h`) - an open nic, not a closed one. Any conclusion drawn from these two has
  to come from a dump taken *while traffic is being pushed at `sipa_eth0`*.
* `rm_res` prints the whole producer/consumer graph with its states, `fifo_cfg` the seventeen common FIFOs,
  `flow_ctrl` the per-FIFO enter/exit counts, and `sipa_eth/sipa_eth0/stats` the driver's own packet counters -
  which are the ones to trust, since a route pointing at the interface is not the same as packets reaching it.

### 13e. The mailbox stops sending after one slow delivery (mainline)
On the mainline kernel the modem went quiet about ninety seconds into every boot - `+CSQ: 44,26` at 67 s, nothing
at 89 s - and stayed quiet until a reboot. It was neither the modem nor the channel: writing an AT command left
the mailbox registers untouched (`/dev/mbox`: INBOX `msg_low` identical before and after), so **the AP was not
sending anything at all**. `mbox-deliver-th` was asleep in `sprd_mbox_deliver_thread`, and the inbox interrupt had
fired **zero** times since boot.

`sprd_mbox_send_data()` queues a message in a software fifo when `phy_ops->send()` fails, and only the inbox
interrupt - raised when a delivery completes or a channel blocks - wakes the thread that drains it. But
`check_mbox_chan_state()` also fails with `-ETIMEDOUT` when the remote core is merely slow to take the previous
message, and that raises no interrupt at all. One such timeout leaves the fifo non-empty for ever, and from then
on every message takes the "fifo is not empty, queue it" path: the AP never speaks to the modem again.

The fix is in the driver, not in the timeout: queueing now wakes the deliver thread itself, and the thread retries
what is still queued (1 ms apart) instead of waiting for an interrupt that may never come.

### 13c. Reading this tty needs `read -t`, and only bash or busybox ash have it
Two ways of timing out a read do **not** work here, and both fail silently:

* **dash has no `read -t`.** It is `/bin/sh` on Ubuntu and Debian, so a `#!/bin/sh` script using `read -t` fails on
  every read with "Illegal option", spins through its timeout and returns an empty reply. The symptom is a daemon
  that answers nothing while burning exactly one timeout of CPU per command (measured: 17.9 s for three 6 s
  commands).
* **The termios timer is ignored.** `stty min 0 time 5` changes nothing: the driver blocks in `sbuf_read` until the
  modem says something, possibly for ever. Visible as `wchan = sbuf_read` with zero CPU time.

`read -t` in bash and in busybox ash uses `poll()`, which this driver does implement, so both work. `mu300-atd` and
`mu300-at` re-exec themselves under bash (or busybox ash) when the shell running them has no `-t`.

Apply `stty` to the already-open descriptor (`stty raw -echo <&3`), never `stty -F /dev/stty_nr1`: the `-F` form is
an extra open and close of the device, which takes the channel away from whoever owns it (13b).

### 13d. Memory shared with the modem must not be mapped write-back (mainline)
The modem and the AP share regions that are reserved **inside** System RAM (no `no-map` in the device tree), and
the modem does not snoop the AP's caches. The vendor 5.4 driver maps them with
`vm_map_ram(pages, count, -1, pgprot_noncached(PAGE_KERNEL))`. Newer kernels removed the `prot` argument from
`vm_map_ram()`, and a port that reaches for `memremap(..., MEMREMAP_WC | MEMREMAP_WB)` instead gets **write-back**,
because write-combine is never available for a linear-mapped region.

The modem then starts, asks for its NV data and never finishes: the NV server reads one good packet and logs
`fail SIZE` on the next, writes three chunks, stalls, and `modem_control` gives up with `wait modem alive timeout`
(`g_modem_state = 8`). `ioremap_wc()` cannot fix it either - the kernel refuses ioremap for System RAM addresses
(`WARNING at arch/arm64/mm/ioremap.c:27`) and the code silently falls back to the cached mapping.

`vmap(pages, count, VM_MAP, prot)` still takes a pgprot, so building the page array and mapping non-cached, the way
the vendor driver did, brings the modem up: `fail SIZE` goes to 0 and "Modem Alive" arrives.

## Wi-Fi (SC2355 / Marlin3)

### 14. Bring-up
* Modules: `pcie-sprd-misc`, `pcie-sprd`, `wcn_bsp`, `sprd_wlan_combo`.
* Firmware and board config come from Android's `/odm/firmware`: `wcnmodem.bin`, `gnssmodem.bin`,
  `wifi_board_config.ini`, `wifi_board_config_ab.ini`. Place them in `/usr/lib/firmware`.
* The realme `wlan_combo` driver falls back to `wifi_board_config_hulk.ini` for unknown projects; the firmware then
  asserts with `CMD_DOWNLOAD_INI / LOAD_INI_DATA_FAILED` and the chip stays in "card dump" state, so `wlan0` cannot
  be brought up (`RTNETLINK answers: No such device`). `kernel/patches/wlan_combo-default-board-config.patch` fixes it.
* `rmmod wcn_bsp` crashes the kernel; reboot instead of reloading the Wi-Fi stack.
* The driver logs `API version not match` for a few command IDs (the realme driver is slightly older than the ZTE
  firmware) and a `WARNING` in `sc2355_free_cmd_buf` (spin_unlock_bh in IRQ context).
* Verified after the fix: the driver parses `wifi_board_config.ini`, `wlan0` comes up, `iw dev wlan0 scan` lists
  nearby networks and `hostapd` (nl80211, WPA2) reaches `AP-ENABLED`. The MAC address is randomized on each load.
* A crash right after installing a module can leave a 0-byte `.ko` on ext4; run `sync` after installing files.

## Mobile data without Android RIL

### 14b. Wi-Fi station mode: decided at boot, and one way only
The SC2355 can be an access point or a client of somebody else's network, but the switch only goes one way:

* The driver creates `wlan0` in **station** mode. hostapd turns it into an access point, and after that nothing
  turns it back. `iw dev wlan0 set type managed` is refused with `Invalid argument` even with the interface down
  and out of the bridge, although `iw phy phy0 info` lists `managed` among the supported modes.
* Deleting and recreating the interface **breaks the radio until the next reboot**: the driver powers the WCN
  chip down and up through an SDIO path (`WCN BASEstart_marlin SDIO card dump`), which is not how Marlin3 is
  attached on this board, and the result is `sprd-wlan: failed to power on WCN!` on every later open. A second
  interface does not help either - with the first one still present the firmware answers scans with
  `sc2355_scan_timeout`.

So the mode belongs to the boot: `mu300-wifi-client.service` runs before `mu300-hotspot.service`, joins the saved
network while `wlan0` is still a station, and holds `/run/mu300-wifi-client.active`, which the hotspot unit refuses
to start on (`ConditionPathExists=!`). Going back to the hotspot needs no reboot, because that is the direction
hostapd can do by itself.

**WPA3/SAE does not work**: wpa_supplicant negotiates SAE correctly but every association is rejected with
`status_code=1`, so Wi-Fi 7 / WPA3-only networks (a "MLO" SSID, for instance) cannot be joined. WPA2 works;
measured on the device: 18 networks scanned, joined, DHCP address, and the Wi-Fi default route (metric 50) taking
precedence over mobile data (metric 100).

### 14c. The Wi-Fi driver can panic the kernel while it is still starting (mainline)
Two boots in a row died at about 29 s with `Unable to handle kernel paging request at 00000000000030b0`,
`pc : sc2355_pcie_tx_cmd_pop_list+0x2c [sprd_wlan_combo]`, reached from `dw_handle_msi_irq` - "Fatal exception in
interrupt", so the kernel stops and LK falls back to Android on the next boot. The captured trace is in
`/sys/fs/pstore/dmesg-ramoops-*`, which Android can read after the failed boot.

The chip reports finished commands with an MSI, and the bus callbacks are registered around `tx_init()` and
`tx_deinit()` - which allocates `hif->tx_mgmt` and sets it back to NULL. An interrupt inside that window walks
`&tx_mgmt->tx_list_cmd.cmd_to_free`, which is offset `0x30b0` from NULL. Both PCIe pop callbacks now return the
buffers to the bus and leave when there is no tx context yet.

### 15. Radio, registration and the data bearer
* AT channels: `/dev/stty_nr0` carries unsolicited results (URCs); `/dev/stty_nr1` is a clean command channel.
* After `modem_control` boots the modem the radio is off (`+CFUN: 0`). Android's RIL (`libimpl-ril.so`) uses the Unisoc
  commands `AT+SFUN=2` (SIM on) and `AT+SFUN=4` (protocol stack on); afterwards `+CFUN: 1` and the modem registers
  (`+CEREG: 2,1,...,13` = E-UTRA-NR dual connectivity, i.e. 5G NSA).
* The network activates the default EPS bearer (CID 1, IPv4v6) by itself. `AT+CGCONTRDP=1` returns the address as
  `a.b.c.d.m.m.m.m` plus DNS servers. `AT+CGDATA="M-ETHER",1` answers `CONNECT` and binds the bearer to
  `sipa_eth0` (`sipa_eth<cid-1>`, raw IP, `NOARP`). Assign the address as /32 and route `default dev sipa_eth0`.
* Measured on a Turkcell 5G NSA SIM: about 9.3 MB/s download and 1.3 MB/s upload. `rootfs/.../mobile-data` implements
  up/down/status/sim-reset and NAT (`nftables masquerade` + MSS clamping) so USB/Wi-Fi clients can share the link.
* AT responses can arrive after a short read timeout and then show up as answers to the next command. Drain the channel
  before sending and read until the final result code (`OK`, `ERROR`, `+CME ERROR`, `CONNECT`).
* Hot-swapping the SIM leaves it busy (`+CME ERROR: 14`) and registration stays at emergency-only (`+CEREG: 2,8`);
  reboot after changing the SIM.
* A SIM without an active data plan still registers and gets an address; TCP handshakes may even succeed, but no data
  flows. Check the plan before debugging the data path.

### 16. Rootfs details found while testing data
* `docker export` leaves an empty `/etc/resolv.conf`: `resolvectl query` works but glibc programs cannot resolve names.
  Link it to `../run/systemd/resolve/stub-resolv.conf`.
* busybox/toybox tar drop xattrs, so `ping` loses `cap_net_raw`; `mu300-fixups.service` restores it.
* Android's uid `system` (1000) is also Ubuntu's first user, so modem device nodes show up as owned by `ubuntu`.

## Default boot

### 17. Linux as default without losing the Android fallback
* LK decrements `tries_remaining` before booting a slot and rolls back when it finds `tries == 1 && !successful`.
  The one-shot trial arms slot b with `tries = 2`.
* Default-Linux mode never sets `successful_boot`. Instead:
  1. init skips the slot-a restore when `/etc/mu300/default-boot` in the rootfs says `linux` (slot b is left at `tries = 1`);
  2. `mu300-boot-ok.service` runs 30 s after `multi-user.target` and writes the `tries = 2` block again.
* A boot that never reaches `mu300-boot-ok` therefore leaves `tries = 1`, and the next boot rolls back to Android.
* Verified: `mu300-next-boot linux` + reboot returned to Linux and re-armed slot b; `mu300-next-boot android` + reboot
  booted slot a.

## Parity with Android

### 18. Services and drivers Android runs that the minimal port lacked
* `cp_diskserver` persists modem NV (`nr_fixnv*`, `nr_runtimenv*`); on first start it immediately wrote pending
  "dirty" NV data, so without it modem NV changes are lost. `refnotify` handles modem reference-clock requests.
  Both run from the same chroot; `srtd` needs Android's binder radio HAL and is skipped.
* Drivers that load cleanly after the modem is up: `sprd_soc_thm`, `thermal-generic-adc`, `sprd_cpu_cooling` (binds
  cpufreq and CPU hotplug cooling to `soc-thmzone` with trips at 70/85/110 °C), `leds-sc27xx-bltc` (RGB status LED),
  `zte_card_holder_det`, `sc27xx-vibra`, `sprd_cp_dvfs`, `sprd_ddr_dvfs`. `zte_sar` loads but the aw9610x SAR sensor
  is not populated on this board (`-201`).
* Android disables audio entirely (`ro.audioserver.disabled=true`, no sound cards) although the device tree has an
  enabled sound card (`unisoc,vbc-v4-codec-sc2730`), the UMP9620 codec and an AW883xx smart amplifier that answers on I2C.
* Android's hotspot (`WifiConfigStoreSoftAp.xml`) lives on the metadata-encrypted `/data`, so Linux cannot read it; it
  has to be copied while Android runs. No factory default Wi-Fi credential is stored in a readable partition.
* RAM: Android uses about 960 MiB of the 1.4 GiB; Ubuntu with all services about 480 MiB, of which ~100 MiB is
  unreclaimable vendor-driver slab. journald is capped (`RuntimeMaxUse=16M`).

### 19. systemd ordering pitfall
* A unit `Before=ssh.socket` that keeps default dependencies is ordered after `basic.target`, while `ssh.socket` is
  before `sockets.target` (before `basic.target`). systemd silently drops `ssh.socket` from the boot transaction and SSH
  never starts. Units that must run before sockets need `DefaultDependencies=no`.

### 20. Diagnosing early power cuts
* The initramfs log loop ends at `switch_root` and journald flushes only after local filesystems are up, so a power cut in
  the first seconds of systemd leaves no log. `mu300-early-recorder.service` keeps writing `dmesg` to the boot_b log area
  for the first five minutes.

### 20b. Telling a userspace reboot from a power cut, and finding who asked for it
`/sys/fs/pstore/console-ramoops-0` survives into the next boot and separates the two cases in one line. A power cut or a
watchdog leaves the log ending mid-sentence; a deliberate reboot ends with the kernel's own

    [   46.468782]c0 [    T1] reboot: Restarting system with command 'shell'

`[T1]` is the task that made the call, and on OpenWrt that is procd: busybox `reboot` does not call the syscall itself,
it hands the request to init, so *every* userspace reboot on this image shows up as pid 1 no matter who started it. The
pstore line therefore says "userspace asked", never who. Three things together do say who, and all three write to
`/mnt/mu300-disk/.mu300/` so they survive the reboot they are recording:

* a wrapper on `/sbin/reboot` that logs uptime and four generations of parent `cmdline` before `exec`ing the real one,
* a line at the top of each `/etc/rc.button/*` handler - OpenWrt's `reset` handler reboots on a *short* press
  (`SEEN < 1`), so a bouncing key is a plausible cause and worth ruling in or out explicitly,
* a kprobe on the syscall for anything that bypasses `/sbin/reboot`, which needs no module:

      echo 'p:mu300reboot __arm64_sys_reboot' > /sys/kernel/debug/tracing/kprobe_events
      echo 1 > /sys/kernel/debug/tracing/events/kprobes/mu300reboot/enable
      cat /sys/kernel/debug/tracing/trace_pipe >> /mnt/mu300-disk/.mu300/reboot-trace.log &

  `trace_pipe` is worth the reader process: the trace buffer itself does not survive the reboot, and procd sleeps a
  second before it calls the syscall, which is long enough for the line to reach the disk.

`gpio-keys` on this board exposes `KEY_VOLUMEDOWN`, `KEY_VOLUMEUP` and `KEY_POWER` (`B: KEY=1c000000000000 0`) and no
`KEY_RESTART`, so `/etc/rc.button/reset` cannot fire here; `/etc/rc.button/power` runs `poweroff`, which the kernel
would log as "Power down" rather than "Restarting system".

## LAN, Wi-Fi bands and regulatory

### 21. One LAN for USB and Wi-Fi
* `br-lan` (192.168.77.1/24) bridges `usb0` and `wlan0`; one dnsmasq serves both.
* cfg80211 refuses to bridge `wlan0` ("Device does not allow enslaving to a bridge") because `IFF_DONT_BRIDGE` stays set:
  the SC2355 driver marks the interface as AP but returns an error from `change_virtual_intf` when tearing down the
  previous firmware mode fails, so cfg80211 skips clearing the flag. `kernel/patches/wlan_combo-allow-bridging-ap.patch`.
* After moving modules, delete old copies: `depmod` indexes every subdirectory and `modprobe` loaded stale drivers from
  an `extra.old/` directory for several boots.

### 22. Regulatory database
* This 5.4 kernel only has the `sforshee` regdb certificate; current `wireless-regdb` is signed by `wens`, so
  `iw reg reload` fails with `-ENODATA`, the domain stays `00` and 5 GHz is `NO-IR`. Android's own `regulatory.db` is
  signed by a different certificate and is rejected too. `kernel/patches/regdb-wens-certificate.patch` adds mainline's
  `wens.hex`. cfg80211 tries to load the database before the rootfs is mounted, so userspace runs `iw reg reload` first.

### 23. Only one AP; 5 GHz AP needs the DS Parameter Set element
* `iw list`: `#{ managed, AP } <= 1` — only one AP interface, so 2.4 and 5 GHz cannot be served simultaneously.
* Symptom: with hostapd on channel 36 the firmware answered `CMD_START_AP` with `SPRD_CMD_STATUS_NOT_SUPPORT_ERROR`
  (HT/VHT), or accepted it and never sent beacons (non-HT), for every country, channel, rate set and HT/VHT/PMF setting
  tried. Android's SoftAP on the same firmware runs on 5180 MHz with 80 MHz.
* Stock (ZTE) and realme `sc2355_start_ap` are identical, so the command payload was captured on Android with a kprobe
  on `sc2355_send_cmd_recv_rsp` (`msg->data` at +24, command id at data-11). Android's beacon contains a DS Parameter Set
  element (`03 01 24`) on 5 GHz — Unisoc's hostapd adds it — while upstream hostapd only adds it on 2.4 GHz. The
  firmware takes the AP channel from that element.
* `kernel/patches/wlan_combo-5ghz-ap-ds-params.patch` inserts the element when hostapd omits it. Verified: 802.11a/n/ac
  AP on channel 36 at 80 MHz (seen by a client, disappears when hostapd stops). The firmware offers 5 GHz AP only on
  36-48 and 149-165 (its ACS channel list); `hotspot-start` uses HT40/VHT80 there, and `hotspot-verify` still falls back
  to 2.4 GHz if the firmware refuses.
* The wiphy rate table lists HT MCS rates as legacy bitrates, so hostapd advertises odd "extended rates" (some with the
  basic-rate bit); Android does the same and the firmware ignores them.
* hostapd's 20/40 MHz coexistence scan (`HT_SCAN`) completes on this driver; the log line after it can lag because
  hostapd's stdout is block-buffered.
* The stock driver prints the SoftAP passphrase to the kernel log (`vendor_softap_convert_para`); Android `dmesg`
  captures contain it.

### 26. Modem resets and mobile data recovery
* The modem firmware occasionally resets: it sends an smsg (type 12, "channel 0 not opened" on the AP side),
  `sipa_delegate: modem_reset`, and `modem_control` stops and reloads the modem through Trusty. It comes back with
  `+CFUN: 0`, no registration and no PDP context, while `sipa_eth0` keeps its stale address, so clients lose internet.
  Android's RIL reconnects silently.
* `mobile-data watch` (`mu300-mobile-data-watch.service`) checks `AT+CGACT?` and the interface address every 30 s and
  runs `up` again after two failed checks; `mobile-data down` sets `/run/mu300-mobile-data-down` so a manual disconnect
  is respected. Verified by switching the radio off: data returned without intervention.

### 27. Where the missing ~550 MiB of RAM goes
* `Memory: 1430144K/2097084K available ... 617788K reserved`. The device tree reserves 464 MiB for the modem firmware
  (`cp-modem@88000000`, needed for 4G/5G), 24 MiB for Trusty (`tos-mem`), 8 MiB SIPC shared memory, 3 MiB DDR training
  data and a few small areas; the kernel image (~35 MiB) and the page tables for 2 GiB (~32 MiB) make up the rest.
  `cma_share` (48 MiB) is still usable for movable pages.
* Not needed on Linux: `logobuffer` (9 MiB, there is no display) and `sysdump-uboot` (16 MiB, bootloader crash dumps).
  `kernel/patches/of-reserved-mem-skip.patch` adds `CONFIG_OF_RESERVED_MEM_SKIP` (the boot image command line is not
  passed on by LK, so a cmdline option alone would not work); MemTotal grew from 1447 to 1473 MiB.
* `mu300-zram.service` adds lz4 zram swap of half the RAM (swappiness 100).


### 28. Mali-G57 GPU (OpenCL) without Android
* The stock `mali_kbase.ko` (DDK r40p0) does not load: 166 of its 335 imported symbol CRCs differ from this kernel.
  realme's `kernel_modules` master branch has the same DDK (`gpu/natt/mali`, r40p0-01eac0, UK 11.36, platform
  `qogirn6pro`); an older checkout of the tree has r34p0 (UK 11.31), which Android's r40p0 userspace would not accept.
  `kernel/build-mali.sh` builds it; it probes `23140000.gpu` as "arch 9.0.9 r0p1" and creates `/dev/mali0`.
* Userspace is Android's `libGLES_mali.so` (it is also `libOpenCL.so` and the Vulkan ICD), a bionic library with a
  37-library closure (VNDK apex, bionic, gralloc/mapper HIDL stubs). It runs in the existing vendor chroot with
  `LD_LIBRARY_PATH` covering vendor, egl, VNDK and bionic; `/dev/ion` is enough for OpenCL buffers.
* Test programs are built for bionic with plain clang (`--target=aarch64-linux-android29`, linked against the device's
  `libc.so`/`libdl.so`/`libOpenCL.so`) and a small `_start` that calls `__libc_init` (`tools/gpu/`), so no NDK is needed.
  `android-gpu-run /system/bin/cltest`: "OpenCL 3.0 v1.r40p0-01eac0", device "Mali-G57 r0p1", 4M-element kernel
  verified correct.
* There is no display, so GLES/Vulkan are only usable off-screen. The driver adds about 45 MiB of memory use.

## OpenWrt

### 29. OpenWrt 25.12 next to Ubuntu
* Layout: the ext4 area holds `/openwrt` (and `/ubuntu`, or Ubuntu directly in the root on first installs);
  `/.mu300/boot-os` selects the system and `init` starts `/lib/systemd/systemd` or procd's `/sbin/init`. The disk stays
  mounted at `/mnt/mu300-disk`; `mu300-os ubuntu|openwrt` switches. `openwrt/build-rootfs.sh` builds the rootfs from the
  official armsr/armv8 tarball (checksum-verified) with apk, our kernel modules flat in `/lib/modules/<release>`
  (ubox kmodloader), the vendor chroot and procd services (`mu300-vendor`, `mu300-hw`, `mu300-post`).
* Cellular WAN is a netifd protocol (`proto mu300cell`, option `apn`), so LuCI/fw4 handle routing, DNS and NAT;
  `mobile-data watch` calls `ifup wan` after modem resets.
* Pitfalls found on the device:
  * procd mounts `/dev` as a 512 KiB tmpfs: copying the 85 MiB Android property area gives empty files and
    `modem_control` never boots the modem (power cut at ~290 s). The property area is now bind-mounted (also on Ubuntu,
    saving the RAM).
  * procd preloads `/lib/libsetlbf.so` into services; the chroot runners unset `LD_PRELOAD` or the bionic linker fails.
  * `ujail` drops capability 38 (CAP_PERFMON), unknown to 5.4, so jailed services crash-loop; `procd-ujail` is removed.
  * OpenWrt's busybox lacks `od`, `timeout`, `losetup`, `telnetd`; the static busybox provides them, plus a tiny
    `mountpoint` script (neither busybox has it).
  * GNU `stty` fails on the modem tty ("unable to perform all requested operations"); it is non-fatal now.
  * `wifi`/netifd wireless handlers are in `wifi-scripts` (with `iwinfo`, `wireless-regdb`), not pulled in by `wpad`.
  * macOS keeps the ECM link inactive after netifd reconfigures `usb0`; a hotplug hook re-enumerates the gadget on every
    LAN ifup.
  * The kernel had no nftables sets (`CONFIG_NF_TABLES_SET`), so fw4's ruleset (`ct state vmap {...}`) was rejected as a
    whole and there was no NAT; the fragment now enables sets, objref, flow offload, redirect, quota and friends.
  * OpenWrt's `regulatory.db` is unsigned; this kernel wants the signed one (Debian's `wireless-regdb`).
  * cfg80211 requests `regulatory.db` at 1.6 s, before the rootfs exists; the direct load fails and the request sits in the
    sysfs firmware fallback for 60 s (no userspace helper answers it, neither on OpenWrt nor with systemd-udevd), and
    `iw reg reload` returns ENOENT meanwhile. `regdb-load` answers the pending requests through `/sys/class/firmware`,
    then reloads; the country is applied before netifd starts hostapd.
  * Attended sysupgrade ("Check online for firmware upgrades") and `sysupgrade` would flash a whole-disk armsr image
    (own GPT, kernel 6.12) over the eMMC and brick the device. The packages are removed and `/sbin/sysupgrade` only allows
    configuration backups.
  * `wifi-scripts` generates an open "OpenWrt" network on first boot; `openwrt-wifi-config` replaces it once (marker
    `/etc/mu300/wifi-configured`) with the imported SSID/WPA2 settings.
* Verified after reboots: 5 GHz AP (channel 36), cellular WAN, a USB client's traffic leaves with the modem's public IP;
  memory use about 140 MiB.
* The early recorder runs from preinit, so a failed OpenWrt boot leaves dmesg, `ps`, `logread` and the Android logcat in
  boot_b for `tools/collect-logs.sh`.


### 30. Installer notes
* Android's `/system/bin/sh` (mksh) does 32-bit arithmetic: byte offsets of the Linux region (27 GiB) overflow, so the
  device script works in sectors. mksh also lets a failing EXIT trap replace the exit status; the installer checks for an
  explicit success line instead.
* `adb shell`/`exec-out` read stdin and swallow answers piped into a script; every call uses `</dev/null`.
* Android restarts once shortly after booting back from a Linux fallback; start the installer when Android has settled.
* A first-generation install (Ubuntu directly in the filesystem root) is replaced by `/ubuntu`; `init` still boots the
  old layout if no `/ubuntu` exists.

## Audio

### 24. No internal audio hardware
* The DT enables a sound card, the UMP9620 codec and an AW883xx amplifier at `6-0034`, and Android disables audio.
  With `i2c-dev`, nothing answers at 0x34 (nor at the bq2560x address 0x6b), and there is no AGDSP firmware partition.
  The board has no speaker path; only Bluetooth or USB-host audio devices are possible.
* **A virtual card is enough for software that only needs a device.** The stock config leaves `SND_DRIVERS` off,
  which is what gates `snd-aloop` and `snd-dummy`; the fragment turns it on and builds both as modules.
  `snd-aloop` then gives card 0 with two PCM devices of eight substreams each - write to `hw:0,0` and the same
  audio comes back on `hw:0,1` - which is what a call bridge or a SIP gateway on the device needs to hand audio
  between two programs. Verified on the device: `/proc/asound/cards` shows `Loopback`, and `/dev/snd` has
  `controlC0`, `pcmC0D0c/p` and `pcmC0D1c/p`. It carries no cellular voice by itself; that still needs the AGDSP
  path below.
* Update: community Android modules show the audio DSP itself is usable. The F50 DT has `audiocp_boot` and `sound@0` but
  no `audio-mem`/`audiodsp-mem` reserved memory (another UMS9620 device uses 0xaf700000 3 MiB and 0xafa00000 6 MiB).
  Their flow loads an AGDSP image taken from a different device into `/sys/devices/platform/audiocp_boot/agdsp`
  (`stop`, write, `start`), binds `sound@0` to `vbc-rxpx-codec-sc27xx`, and gets a `sprdphone-sc2730` card with Bluetooth
  SCO call audio. The Unisoc ASoC/AGDSP driver sources are in the realme `unisoc-5.4` kernel_modules tree; porting this
  to Linux is future work (A2DP over BlueZ does not need the DSP).

## Bluetooth

### 25. SC2355 Bluetooth on BlueZ
* Transport: `sprdbt_tty` (realme `wcn/bluetooth/driver/tty-pcie`, built with `BSP_BOARD_UNISOC_WCN_SOCKET=pcie`) exposes
  an H4 tty `/dev/ttyBT0` over the WCN PCIe link and registers a `bluetooth` rfkill that powers the BT function.
  `btattach -B /dev/ttyBT0 -P h4` creates `hci0`.
* Vendor init (Android `libbt-sprd_suite`, Marlin3): before the stack starts, send `0xFCA0` with the 176-byte PSKey block
  from `bt_configure_pskey.ini` (BD address at bytes 20..25, little endian), `0xFCA2` with the 252-byte RF block from
  `bt_configure_rf.ini`, then `0xFCA1 00 00 01` (dual mode, enable). `tools/bt-init/mu300-bt-init.c` does this. Without the
  PSKey upload the controller reports a fixed placeholder address.
* The firmware advertises Hold Mode and Park State in its LMP features, but `Write Default Link Policy Settings` returns
  `Invalid HCI Command Parameters` for any value that includes them (0x0000/0x0001/0x0004/0x0005 accepted, 0x0007 rejected).
  The 5.4 kernel sets every advertised mode, so the init sequence aborts and `hciconfig hci0 up` fails with `EINVAL`.
  `kernel/patches/bluetooth-marlin3-link-policy.patch` requests only Role Switch and Sniff (Bluetooth is built in, so this
  needs the kernel rebuild).
* Android keeps the real BT address in `/data/vendor/bluetooth/btmac.txt` on encrypted `/data`; Linux uses
  `BDADDR=` from `/etc/mu300/bluetooth.conf` or a stable locally administered address derived from `machine-id`.
* Verified: `bluetoothd` powers the adapter and LE/BR-EDR scanning lists nearby devices.
* Rebuilding with a modified tree appends `-dirty` to the kernel release and breaks module loading; `.scmversion` with
  `-gb50db5b6224c` in the source tree keeps the release string stable.
