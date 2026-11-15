#!/bin/sh
. /tmp/suite-env.sh
set -u
# nothing may go to the network in here: the device cases are about local files
export MU300_RELEASE_URL=http://127.0.0.1:1/r MU300_API_URL=http://127.0.0.1:1 MU300_FETCH_DELAY=0 MU300_FETCH_RETRIES=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: [$2] != [$3]"; fi; }
reset() { rm -rf /mnt/mu300-disk/openwrt /mnt/mu300-disk/openwrt.old /mnt/mu300-disk/openwrt.new; cp -a /opt/old-base /mnt/mu300-disk/openwrt; }
loadup() { MU300_LIB=1; export MU300_LIB; . /tmp/newimg/opt/mu300/bin/mu300-update; MU300_DISK=/mnt/mu300-disk; STAGE=/tmp/stage; export MU300_DISK STAGE; }
echo "== A4 fallback from a clean old system"
reset; loadup
OLD=/mnt/mu300-disk/openwrt
cp /tmp/new-nocarry.tar.gz /tmp/stage/mu300-immortalwrt-rootfs.tar.gz
MU300_UPDATE_KEEP=list; export MU300_UPDATE_KEEP
( apply_one openwrt $TAG_NOCARRY ) >/tmp/fb2.out 2>/tmp/fb2.err; echo "fallback_rc=$?"
ok version "$(cat $OLD/etc/mu300/image-version)" $TAG_NOCARRY
if [ -r "$OLD/etc/mu300/update-report" ]; then echo "PASS report readable"; else echo "FAIL report unreadable"; fi
