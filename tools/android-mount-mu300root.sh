#!/system/bin/sh
# Attach the mu300root ext4 (free eMMC region) on Android via a bounded loop device and mount it.
# usage: android-mount-mu300root.sh <mountpoint>   |   android-mount-mu300root.sh -u <mountpoint>
set -e
# region of the free eMMC space after the last GPT partition (install.sh passes the values it computed)
OFF=${MU300_OFF:-27762098176}
# Android's shell does 32-bit arithmetic: byte offsets of this region overflow there, so the size is never
# computed here. Callers that know it pass MU300_SIZE (install.sh, tools/reset-password.sh); without it the loop
# simply spans to the end of the disk, which mounts any size of filesystem.
SIZE=${MU300_SIZE:-}

if [ "$1" = -u ]; then
    L=$(grep " $2 " /proc/mounts | cut -d' ' -f1)
    umount "$2"; [ -n "$L" ] && losetup -d "$L"; echo UNMOUNTED; exit 0
fi
MP=$1
# never attach the same ext4 twice (two loops mounting one filesystem corrupts it); a leftover loop from an
# interrupted run is reused when nothing has it mounted
REUSE=
for o in /sys/block/loop*/loop/offset; do
    [ "$(cat "$o" 2>/dev/null)" = "$OFF" ] || continue
    b=${o%/loop/offset}; b=${b##*/}
    if grep -q "^/dev/block/$b " /proc/mounts; then echo "ALREADY-MOUNTED $b"; exit 1; fi
    REUSE=/dev/block/$b
done
if [ -n "$REUSE" ]; then
    L=$REUSE
    mkdir -p "$MP"
    mount -t ext4 -o noatime "$L" "$MP"
    echo "MOUNTED $L on $MP"
    exit 0
fi
f=$(losetup -f 2>&1 | grep -o '/dev/block/loop[0-9]*' | head -1)
n=${f##*loop}
[ -n "$n" ] || { echo NO-LOOP-INDEX; exit 1; }
[ -e /sys/block/loop$n/dev ] || { echo NO-SYSFS-loop$n; exit 1; }
L=/dev/block/loop$n
# ueventd may create the node concurrently; only fail if it still does not exist
[ -b "$L" ] || mknod "$L" b $(cut -d: -f1 /sys/block/loop$n/dev) $(cut -d: -f2 /sys/block/loop$n/dev) 2>/dev/null || [ -b "$L" ]
[ ! -e /sys/block/loop$n/loop/backing_file ] || { echo LOOP-BUSY-$L; exit 1; }
if [ -n "$SIZE" ]; then
    losetup -o $OFF -S $SIZE "$L" /dev/block/mmcblk0
else
    losetup -o $OFF "$L" /dev/block/mmcblk0
fi
[ "$(cat /sys/block/loop$n/loop/offset)" = "$OFF" ] && [ "$(cat /sys/block/loop$n/loop/backing_file)" = /dev/block/mmcblk0 ] || { echo LOOP-MISMATCH; losetup -d "$L"; exit 1; }
[ -z "$SIZE" ] || [ "$(blockdev --getsize64 $L)" = "$SIZE" ] || { echo LOOP-SIZE-MISMATCH; losetup -d "$L"; exit 1; }
# ext4 superblock at 1024: s_magic @+56 (0xEF53), s_volume_name @+120 (16 bytes)
magic=$(dd if="$L" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$magic" = 53ef ] || { echo "NO-EXT4 magic=$magic"; losetup -d "$L"; exit 1; }
label=$(dd if="$L" bs=1 skip=1144 count=16 2>/dev/null | tr -d '\000')
[ "$label" = mu300root ] || { echo "NOT-MU300ROOT label=$label"; losetup -d "$L"; exit 1; }
mkdir -p "$MP"
mount -t ext4 -o noatime "$L" "$MP"
echo "MOUNTED $L on $MP"
