#!/bin/sh
# MU300 / ZTE F50 Linux installer. Run on a macOS/Linux host with the device booted in rooted Android (adb + su).
#
#   ./install.sh --check         only inspect the device: is the free eMMC region there and empty? (writes nothing)
#   ./install.sh                 install Ubuntu, OpenWrt or both from the prebuilt release images
#   ./install.sh --build         build kernel outputs/root filesystems locally instead (see README "Build and run")
#
# Prebuilt: needs adb, python3, lz4, curl. Downloads the images of release $MU300_RELEASE and checks their sha256.
# Build:    needs adb, docker, python3, lz4 and the kernel outputs in $MU300_KERNEL_OUT (default: out/, kernel/build-all.sh).
# The published images contain no proprietary files: Wi-Fi/Bluetooth firmware and the Android modem/GPU userspace are
# pulled from *your* device into $MU300_WORK (default: work/), never leave the host except to your device.
set -eu
TOP=$(cd "$(dirname "$0")" && pwd)
KOUT=${MU300_KERNEL_OUT:-$TOP/out}
WORK=${MU300_WORK:-$TOP/work}
OWRT_VER=25.12.5
RELEASE=${MU300_RELEASE:-v2026.09.21}
REPO=${MU300_REPO:-dikeckaan/mu300-linux}
T=/data/local/tmp
MODE=prebuilt; CHECK_ONLY=0
for a in "$@"; do
    case $a in
        --check) CHECK_ONLY=1 ;;
        --build) MODE=build ;;
        --prebuilt) MODE=prebuilt ;;
        -h|--help) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "unknown option $a (see --help)" >&2; exit 2 ;;
    esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask() { # ask VAR "question" default
    printf '%s [%s]: ' "$2" "$3"; read -r _a; [ -n "$_a" ] || _a=$3; eval "$1=\$_a"; }
# fetch URL OUT: GitHub's release CDN throttles a single connection hard in some regions (measured 0.2 MB/s
# against a 180 Mbit/s line), so pull the file as parallel ranges and fall back to one stream when that fails.
fetch() {
    _u=$1; _o=$2
    _len=$(curl -fsSLI "$_u" | awk 'tolower($1) == "content-length:" {print $2}' | tr -d '\r' | tail -n1)
    _jobs=${MU300_FETCH_JOBS:-8}
    if [ -z "$_len" ] || [ "$_len" -lt 8000000 ] 2>/dev/null || [ "$_jobs" -le 1 ] 2>/dev/null; then
        curl -fL --retry 3 --progress-bar -o "$_o" "$_u"
        return
    fi
    _part=$((_len / _jobs + 1)); _i=0; _pids=
    rm -f "$_o".part*
    while [ $_i -lt "$_jobs" ]; do
        _s=$((_i * _part)); _e=$((_s + _part - 1))
        [ $_e -ge "$_len" ] && _e=$((_len - 1))
        curl -fsSL --retry 3 -r "$_s-$_e" -o "$_o.part$_i" "$_u" &
        _pids="$_pids $!"; _i=$((_i + 1))
    done
    _ok=1
    for _p in $_pids; do wait "$_p" || _ok=0; done
    if [ $_ok = 1 ]; then
        cat "$_o".part* > "$_o"; rm -f "$_o".part*
        [ "$(wc -c < "$_o" | tr -d ' ')" = "$_len" ] && return
    fi
    rm -f "$_o".part*
    echo "  parallel download failed, retrying as a single stream"
    curl -fL --retry 3 --progress-bar -o "$_o" "$_u"
}

# adb shell/exec-out read stdin; never let them eat the answers typed (or piped) into this script
su_do() { adb shell "su -c '$1'" </dev/null | tr -d '\r'; }

# ---------------------------------------------------------------- preflight
say "Checking host tools and device"
need="adb"
[ $CHECK_ONLY = 1 ] || { [ $MODE = build ] && need="adb docker python3 lz4" || need="adb python3 lz4 curl"; }
for c in $need; do command -v $c >/dev/null || die "$c not found"; done
if [ $CHECK_ONLY = 0 ] && [ $MODE = build ]; then
    [ -f "$KOUT/Image" ] && ls "$KOUT"/modules/*.ko >/dev/null 2>&1 || die "kernel outputs missing in $KOUT (run kernel/build-all.sh)"
fi
. "$TOP/tools/linux-mode.sh"
require_android
[ "$(su_do 'id -u')" = 0 ] || die "su does not work on the device"
model="$(su_do 'getprop ro.product.model') / $(su_do 'getprop ro.product.device')"
echo "device: $model"
case "$model" in *MU300*|*F50*|*mu300*) ;; *) ask go "This does not look like a ZTE F50/MU300. Continue anyway? (yes/no)" no; [ "$go" = yes ] || exit 1 ;; esac
[ "$(su_do 'getprop ro.boot.slot_suffix')" = _a ] || die "Android must be running from slot a"

# ---------------------------------------------------------------- free eMMC region
say "Locating free eMMC space after the last partition"
set -- $(su_do 'e=0; for p in /sys/block/mmcblk0/mmcblk0p*; do x=$(( $(cat $p/start) + $(cat $p/size) )); [ $x -gt $e ] && e=$x; done; echo $e $(cat /sys/block/mmcblk0/size)')
[ $# -eq 2 ] || die "could not read the partition table from the device (is su granted? try again)"
last_end=$1; disk=$2
start=$(( (last_end / 4096 + 1) * 4096 ))
end=$(( ((disk - 34) / 4096 - 1) * 4096 ))
OFF=$((start * 512)); SIZE=$(( (end - start) * 512 ))
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }
# What each choice needs: the installed systems measure ~320 MiB (OpenWrt) and ~580 MiB (Ubuntu), and an update
# keeps the previous one as <os>.old while the new one is unpacked, so allow for two of each plus working room.
NEED_OPENWRT=$((800 * 1024 * 1024)); NEED_UBUNTU=$((1600 * 1024 * 1024)); NEED_BOTH=$((2400 * 1024 * 1024))
echo "eMMC: $(gib $((disk * 512))) ($disk sectors), partitions end at $(gib $((last_end * 512))) (sector $last_end), free after them: $(gib $SIZE)"
# Smaller eMMC variants leave less room behind userdata, and how much is needed depends on the choice further
# down - OpenWrt alone fits in a few hundred megabytes. So refuse only what cannot hold anything at all, and
# check the real requirement once the systems are known. There is nowhere else to put this region on these
# devices: userdata is metadata-encrypted (dm-default-key), so an image file inside it cannot be read from
# Linux, and the spare-looking blackbox and fulldumpdb partitions are written by the firmware itself.
[ $SIZE -ge $((700 * 1024 * 1024)) ] || die "only $((SIZE / 1048576)) MiB of free space after the last partition: this device has a different layout, nothing is changed.
Please report the numbers above (eMMC size and where the partitions end); they identify the variant."
# an existing installation defines the region (it may have been created with a slightly different size)
existing=no
for cand in $OFF 27762098176; do
    m=$(su_do "dd if=/dev/block/mmcblk0 bs=1 skip=$((cand + 1080)) count=2 2>/dev/null | od -An -tx1" | tr -d ' ')
    l=$(su_do "dd if=/dev/block/mmcblk0 bs=1 skip=$((cand + 1144)) count=16 2>/dev/null" | tr -d '\000')
    if [ "$m" = 53ef ] && [ "$l" = mu300root ]; then
        blocks=$(su_do "dd if=/dev/block/mmcblk0 bs=1 skip=$((cand + 1028)) count=4 2>/dev/null | od -An -tu4" | tr -d ' ')
        OFF=$cand; SIZE=$((blocks * 4096)); existing=yes; break
    fi
done
echo "Linux region: offset $OFF, $(gib $SIZE), existing mu300root filesystem: $existing"
# unpartitioned space should be unused: sample 16 x 1 MiB across the region and count non-zero bytes
DIRTY=0
if [ $existing = no ]; then
    step=$(( SIZE / 1048576 / 16 ))
    probe=""; i=0
    while [ $i -lt 16 ]; do probe="$probe $(( OFF / 1048576 + i * step ))"; i=$((i + 1)); done
    DIRTY=$(su_do "n=0; for s in $probe; do c=\$(dd if=/dev/block/mmcblk0 bs=1048576 skip=\$s count=1 2>/dev/null | tr -d \"\\000\" | wc -c); [ \$c -gt 0 ] && n=\$((n + 1)); done; echo \$n")
    echo "data check: $DIRTY of 16 samples contain non-zero data"
fi
if [ $existing = yes ]; then
    verdict="OK: a MU300 Linux installation is already present (it can be kept or replaced)"
elif [ "$DIRTY" -gt 0 ]; then
    verdict="WARNING: the unpartitioned space is not empty; it may be used by this firmware. Installing overwrites it"
elif [ $SIZE -ge $((20 * 1024 * 1024 * 1024)) ]; then
    verdict="OK: free and empty, same layout as the tested device (~32 GiB after userdata on the 64 GB eMMC)"
elif [ $SIZE -ge $NEED_BOTH ]; then
    verdict="OK: free and empty, smaller than on the tested device but enough for both systems"
elif [ $SIZE -ge $NEED_UBUNTU ]; then
    verdict="OK: free and empty, but room for one system only (Ubuntu or OpenWrt, not both)"
else
    verdict="OK: free and empty, but small: OpenWrt fits, Ubuntu does not"
fi
echo "result: $verdict"
if [ $CHECK_ONLY = 1 ]; then
    echo; echo "Nothing was written. Android version: $(su_do 'getprop ro.build.display.id')"
    exit 0
fi
if [ "$DIRTY" -gt 0 ]; then
    ask ow "Type overwrite to use this region anyway" no
    [ "$ow" = overwrite ] || die "cancelled"
fi

# ---------------------------------------------------------------- choices
say "What should be installed?"
echo "  1) Ubuntu 24.04 LTS (full distribution, apt, ~500 MiB RAM in use)"
echo "  2) OpenWrt $OWRT_VER (router, LuCI web UI, ~140 MiB RAM in use)"
echo "  3) both (switch later with: mu300-os ubuntu|openwrt)"
[ $SIZE -lt $NEED_BOTH ] && echo "  (this device has $(gib $SIZE): $([ $SIZE -ge $NEED_UBUNTU ] && echo 'one system fits, not both' || echo 'only OpenWrt fits'))"
ask choice "Choice" 3
case $choice in 1) OSES=ubuntu ;; 2) OSES=openwrt ;; 3) OSES="ubuntu openwrt" ;; *) die "invalid choice" ;; esac
need=$NEED_OPENWRT; [ "$OSES" = ubuntu ] && need=$NEED_UBUNTU; [ "$OSES" = "ubuntu openwrt" ] && need=$NEED_BOTH
[ $SIZE -ge $need ] || die "that choice needs about $((need / 1048576)) MiB and this device has $((SIZE / 1048576)) MiB of free space"
BOOT_OS=${OSES%% *}
[ "$choice" = 3 ] && { ask BOOT_OS "Which one should boot (ubuntu/openwrt)" ubuntu; case $BOOT_OS in ubuntu|openwrt) ;; *) die "invalid system" ;; esac; }
ask dl "Boot Linux by default instead of Android (falls back to Android if Linux fails)? (yes/no)" yes
DEFAULT_LINUX=0; [ "$dl" = yes ] && DEFAULT_LINUX=1
ask hs "Copy Android's hotspot name and password to Linux? (yes/no)" yes  # kept as-is when updating
IMPORT_HOTSPOT=0; [ "$hs" = yes ] && IMPORT_HOTSPOT=1
ask gpu "Include the Mali GPU (OpenCL) userspace (~90 MiB)? (yes/no)" yes
FORMAT=0; WIPE_LEGACY=0; UPDATE=0
if [ $existing = no ]; then
    FORMAT=1
else
    echo
    echo "  A MU300 Linux installation is already on this device."
    echo "    update  reinstall the systems and keep settings and data (/etc/mu300, users and home directories,"
    echo "            SSH host keys, OpenWrt UCI config; the hotspot settings are kept too)"
    echo "    wipe    erase the Linux filesystem and install from scratch"
    ask mode "update or wipe" update
    case $mode in
        update) UPDATE=1 ;;
        wipe) FORMAT=1 ;;
        *) die "invalid choice" ;;
    esac
    # a new /ubuntu replaces an Ubuntu installed directly in the filesystem root (first-generation layout)
    case " $OSES " in *" ubuntu "*) [ $FORMAT = 0 ] && WIPE_LEGACY=1 ;; esac
fi
printf 'Password for the "ubuntu" user (Ubuntu) and "root" (OpenWrt): '
[ -t 0 ] && stty -echo; read -r pw1; printf '\nRepeat: '; read -r pw2; [ -t 0 ] && stty echo; echo
[ "$pw1" = "$pw2" ] && [ ${#pw1} -ge 6 ] || die "passwords differ or are shorter than 6 characters"

# ---------------------------------------------------------------- pull vendor data from the device
mkdir -p "$WORK/dumps" "$WORK/firmware"
say "Pulling device data into $WORK (stays on this computer)"
adb exec-out "su -c 'cat /dev/block/by-name/boot_a'" </dev/null > "$WORK/dumps/boot_a.img"
adb exec-out "su -c 'dd if=/dev/block/by-name/misc bs=4096 count=1 2>/dev/null'" </dev/null > "$WORK/dumps/misc-head.bin"
[ -d "$WORK/android-subset" ] || sh "$TOP/android-vendor/extract-subset.sh" "$WORK/android-subset"
for f in wcnmodem.bin gnssmodem.bin wifi_board_config.ini wifi_board_config_ab.ini bt_configure_pskey.ini bt_configure_rf.ini; do
    for d in /odm/firmware /vendor/firmware /vendor/etc; do
        if [ "$(su_do "[ -f $d/$f ] && echo y")" = y ]; then adb exec-out "su -c 'cat $d/$f'" </dev/null > "$WORK/firmware/$f"; break; fi
    done
done
if [ "$gpu" = yes ] && [ ! -d "$WORK/android-gpu-subset" ]; then
    sh "$TOP/android-vendor/extract-gpu-subset.sh" "$WORK/android-gpu-subset"
fi

if [ $MODE = prebuilt ]; then
# ---------------------------------------------------------------- prebuilt images
REL=$WORK/release/$RELEASE
mkdir -p "$REL"
# MU300_RELEASE_URL: another location with the same files (e.g. a local test server)
base=${MU300_RELEASE_URL:-https://github.com/$REPO/releases/download/$RELEASE}
say "Downloading release $RELEASE"
curl -fsSL -o "$REL/SHA256SUMS" "$base/SHA256SUMS" || die "cannot download $base/SHA256SUMS"
files=mu300-kernel.tar.gz
for os in $OSES; do files="$files mu300-$os-rootfs.tar.gz"; done
for f in $files; do
    want=$(awk -v f="$f" '$2 == f || $2 == "*" f {print $1}' "$REL/SHA256SUMS")
    [ -n "$want" ] || die "$f is not part of release $RELEASE"
    have=$( (shasum -a 256 "$REL/$f" 2>/dev/null || sha256sum "$REL/$f" 2>/dev/null) | cut -d' ' -f1)
    if [ "$have" != "$want" ]; then
        echo "  $f"
        fetch "$base/$f" "$REL/$f.part" || die "download of $f failed"
        have=$( (shasum -a 256 "$REL/$f.part" 2>/dev/null || sha256sum "$REL/$f.part") | cut -d' ' -f1)
        [ "$have" = "$want" ] || die "checksum mismatch for $f"
        mv "$REL/$f.part" "$REL/$f"
    fi
done
rm -rf "$REL/kernel" && mkdir -p "$REL/kernel" && tar -xzf "$REL/mu300-kernel.tar.gz" -C "$REL/kernel"
KOUT=$REL/kernel
BUSYBOX=$KOUT/busybox; LOGDW=$KOUT/logdw
say "Adding the vendor files from your device to the images"
for os in $OSES; do
    python3 "$TOP/tools/vendor-overlay.py" --os $os --firmware "$WORK/firmware" --android-subset "$WORK/android-subset" \
      $([ -d "$WORK/android-gpu-subset" ] && [ "$gpu" = yes ] && echo --gpu-subset "$WORK/android-gpu-subset") \
      --out "$WORK/mu300-vendor-$os.tar.gz"
done
PWHASH=$(printf '%s\n' "$pw1" | python3 "$TOP/tools/sha512crypt.py")
else
# ---------------------------------------------------------------- build
say "Building helper binaries"
mkdir -p "$WORK/out" "$WORK/tools/logdw" "$WORK/tools/bt-init" "$WORK/tools/gpu"
rm -rf "$WORK/out/modules" && cp -R "$KOUT/modules" "$WORK/out/modules"
cp "$KOUT/modules.builtin" "$KOUT/modules.builtin.modinfo" "$WORK/out/" 2>/dev/null || true
docker build -q -t mu300-ubuntu:24.04 "$TOP/rootfs" >/dev/null
docker run --rm mu300-ubuntu:24.04 cat /bin/busybox > "$WORK/busybox"; chmod +x "$WORK/busybox"
docker run --rm -v "$TOP/tools":/src:ro -v "$WORK/tools":/o mu300-kbuild sh -c '
  gcc -O2 -static -o /o/logdw/logdw /src/logdw/logdw.c &&
  gcc -O2 -static -o /o/bt-init/mu300-bt-init /src/bt-init/mu300-bt-init.c'
if [ -d "$WORK/android-gpu-subset" ]; then
    L=$(mktemp -d "$WORK/cllibs.XXXX")
    cp "$WORK/android-gpu-subset/vendor/lib64/libOpenCL.so" "$WORK/android-subset/apex/com.android.runtime/lib64/bionic/libc.so" \
       "$WORK/android-subset/apex/com.android.runtime/lib64/bionic/libdl.so" "$L/"
    docker run --rm -v "$TOP/tools/gpu":/w -v "$L":/l:ro -v "$WORK/tools/gpu":/o mu300-kbuild sh -c \
      'ln -sf /usr/bin/clang-12 /usr/local/bin/clang; cp -r /w /tmp/gpu && sh /tmp/gpu/build.sh /l && cp /tmp/gpu/cltest /o/'
    rm -rf "$L"
fi

# MU300_REUSE_BUILD=1 keeps rootfs tarballs from an earlier run of this script
reuse() { [ "${MU300_REUSE_BUILD:-0}" = 1 ] && [ -s "$WORK/mu300-$1.tar.gz" ] && echo "reusing $WORK/mu300-$1.tar.gz"; }
case " $OSES " in *" ubuntu "*) reuse ubuntu || {
    say "Building the Ubuntu root filesystem"
    B=$(mktemp -d "$WORK/ubuntu-build.XXXX")
    tar -C "$TOP/rootfs" --exclude ./base.tar --exclude './*.tar.gz' -cf - . | tar -xf - -C "$B"
    cid=$(docker create mu300-ubuntu:24.04 /bin/true); docker export "$cid" > "$B/base.tar"; docker rm "$cid" >/dev/null
    gpuargs=""
    [ -d "$WORK/android-gpu-subset" ] && gpuargs="-v $WORK/android-gpu-subset:/android-gpu-subset:ro -v $WORK/tools/gpu/cltest:/cltest:ro"
    # shellcheck disable=SC2086
    docker run --rm -v "$B":/w -v "$WORK/out/modules":/kmods:ro -v "$WORK/out":/kout:ro -v "$WORK/firmware":/firmware:ro \
      -v "$WORK/android-subset":/android-subset:ro -v "$WORK/tools/logdw/logdw":/logdw:ro \
      -v "$WORK/tools/bt-init/mu300-bt-init":/bt-init:ro $gpuargs mu300-ubuntu:24.04 bash /w/assemble.sh >/dev/null
    mv "$B/mu300-ubuntu-24.04-rootfs.tar.gz" "$WORK/mu300-ubuntu.tar.gz"; rm -rf "$B"; } ;;
esac
case " $OSES " in *" openwrt "*) reuse openwrt || {
    say "Building the OpenWrt root filesystem"
    MU300_INPUTS="$WORK" sh "$TOP/openwrt/build-rootfs.sh" mu300-openwrt-rootfs.tar.gz >/dev/null
    mv "$TOP/openwrt/mu300-openwrt-rootfs.tar.gz" "$WORK/mu300-openwrt.tar.gz"; } ;;
esac
BUSYBOX=$WORK/busybox; LOGDW=$WORK/tools/logdw/logdw
PWHASH=$(printf '%s' "$pw1" | docker run --rm -i mu300-ubuntu:24.04 openssl passwd -6 -stdin)
fi

say "Building the boot image"
sed "s/^ROOT_OFFSET=[0-9]*/ROOT_OFFSET=$OFF/" "$TOP/boot/init" > "$WORK/init"
python3 "$TOP/boot/build-boot-image.py" --stock-boot "$WORK/dumps/boot_a.img" --misc-head "$WORK/dumps/misc-head.bin" \
  --kernel "$KOUT/Image" --modules "$KOUT/modules" --init "$WORK/init" --busybox "$BUSYBOX" \
  --logdw "$LOGDW" --ueventd-perms "$TOP/android-vendor/ueventd-perms.sh" \
  --android-subset "$WORK/android-subset" --out "$WORK/boot-linux-slotb.img" >/dev/null

# ---------------------------------------------------------------- confirm and install
say "Ready to install"
echo "  source:         $([ $MODE = prebuilt ] && echo "prebuilt release $RELEASE + vendor files from this device" || echo "local build")"
echo "  systems:        $OSES (boots: $BOOT_OS)"
echo "  default boot:   $([ $DEFAULT_LINUX = 1 ] && echo Linux || echo Android, Linux on demand)"
echo "  filesystem:     $([ $FORMAT = 1 ] && echo "CREATE new ext4 (erases the Linux region)" || echo "keep existing")"
[ $UPDATE = 1 ] && echo "  update:         settings and user data of the chosen systems are kept, everything else is replaced"
[ $UPDATE = 0 ] && [ $FORMAT = 0 ] && echo "  note:           the chosen systems are installed fresh; their previous files and settings are replaced"
echo "  writes:         Linux region at offset $OFF, boot_b, 32 bytes of misc (boot_a, GPT and userdata are not touched)"
ask confirm "Type INSTALL to continue" no
[ "$confirm" = INSTALL ] || die "cancelled"

say "Copying to the device"
adb push "$TOP/tools/android-mount-mu300root.sh" "$TOP/tools/android-install.sh" $T/ >/dev/null
for os in $OSES; do
    if [ $MODE = prebuilt ]; then
        adb push "$REL/mu300-$os-rootfs.tar.gz" $T/mu300-$os.tar.gz >/dev/null
        adb push "$WORK/mu300-vendor-$os.tar.gz" $T/mu300-vendor-$os.tar.gz >/dev/null
    else
        adb push "$WORK/mu300-$os.tar.gz" $T/mu300-$os.tar.gz >/dev/null
    fi
done
env=$(mktemp)
printf 'OFF=%s\nSIZE=%s\nOFF_S=%s\nSIZE_S=%s\nFORMAT=%s\nOSES="%s"\nWIPE_LEGACY=%s\nUPDATE=%s\nBOOT_OS=%s\nDEFAULT_LINUX=%s\nIMPORT_HOTSPOT=%s\nPWHASH='"'"'%s'"'"'\n' \
  "$OFF" "$SIZE" "$((OFF / 512))" "$((SIZE / 512))" "$FORMAT" "$OSES" "$WIPE_LEGACY" "$UPDATE" "$BOOT_OS" "$DEFAULT_LINUX" "$IMPORT_HOTSPOT" "$PWHASH" > "$env"
adb push "$env" $T/mu300-install.env >/dev/null; rm -f "$env"
su_do "sh $T/android-install.sh" | tee "$WORK/device-install.log"
grep -q MU300-INSTALL-OK "$WORK/device-install.log" || die "installation on the device failed; boot_b and misc were not changed"

say "Writing boot_b and arming slot b"
EXP=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$WORK/boot-linux-slotb.json")
adb push "$WORK/boot-linux-slotb.img" $T/mu300-boot.img >/dev/null
adb push "$WORK/boot-linux-slotb.misc-slot-b-trial.bin" $T/mu300-bc-b.bin >/dev/null
[ "$(su_do "sha256sum $T/mu300-boot.img" | cut -d' ' -f1)" = "$EXP" ] || die "pushed boot image hash mismatch"
su_do "dd if=$T/mu300-boot.img of=/dev/block/by-name/boot_b bs=4M && sync"
[ "$(su_do 'sha256sum /dev/block/by-name/boot_b' | cut -d' ' -f1)" = "$EXP" ] || die "boot_b verify failed (slot a still active, Android keeps booting)"
su_do "dd if=$T/mu300-bc-b.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc && sync && rm $T/mu300-boot.img $T/mu300-bc-b.bin"

# on-device switch for later: one command in Android instead of plugging into a computer (needs Magisk)
say "Installing the on-device switch (Magisk module)"
sh "$TOP/tools/install-magisk-module.sh" || echo "  (skipped; ./install.sh keeps working either way)"

say "Done. Rebooting into $BOOT_OS"
echo "  USB network: 192.168.77.1   SSH: $([ "$BOOT_OS" = ubuntu ] && echo ubuntu@192.168.77.1 || echo root@192.168.77.1, LuCI http://192.168.77.1)"
echo "  switch systems: mu300-os ubuntu|openwrt   back to Android: mu300-next-boot android"
echo "  back to Linux from Android (with Magisk): su -c mu300-linux"
adb reboot </dev/null
