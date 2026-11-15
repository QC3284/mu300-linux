#!/bin/sh
. /tmp/suite-env.sh
set -u
# nothing may go to the network in here: the device cases are about local files
export MU300_RELEASE_URL=http://127.0.0.1:1/r MU300_API_URL=http://127.0.0.1:1 MU300_FETCH_DELAY=0 MU300_FETCH_RETRIES=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: [$2] != [$3]"; fi; }
reset() { rm -rf /mnt/mu300-disk/openwrt /mnt/mu300-disk/openwrt.old /mnt/mu300-disk/openwrt.new; cp -a /opt/old-base /mnt/mu300-disk/openwrt; }
loadup() { MU300_LIB=1; export MU300_LIB; . /tmp/newimg/opt/mu300/bin/mu300-update; MU300_DISK=/mnt/mu300-disk; STAGE=/tmp/stage; export MU300_DISK STAGE; }
echo "== A3 negative: an image without the carry helper is refused"
reset; loadup
OLD=/mnt/mu300-disk/openwrt
cp /tmp/new-nocarry.tar.gz /tmp/stage/mu300-immortalwrt-rootfs.tar.gz
( apply_one openwrt $TAG_NOCARRY ) >/tmp/neg.out 2>/tmp/neg.err; echo "negative_rc=$?"
if grep -q "does not bring what carries your files over" /tmp/neg.err /tmp/neg.out 2>/dev/null; then echo "PASS negative message"; else echo "FAIL negative message"; fi
ok negative_version "$(cat $OLD/etc/mu300/image-version)" $TAG_OLD
ok negative_marker "$(cat $OLD/root/mine.txt 2>/dev/null)" notes
ok negative_no_new "no" "$(test -e /mnt/mu300-disk/openwrt.new && echo yes || echo no)"
echo "== A3b fallback MU300_UPDATE_KEEP=list"
cp /tmp/new-nocarry.tar.gz /tmp/stage/mu300-immortalwrt-rootfs.tar.gz
MU300_UPDATE_KEEP=list; export MU300_UPDATE_KEEP
( apply_one openwrt $TAG_NOCARRY ) >/tmp/fb.out 2>/tmp/fb.err; echo "fallback_rc=$?"
echo "fallback_err=$(tail -n 2 /tmp/fb.err | tr "\\n" "|")"
F=$OLD
ok fallback_version "$(cat $F/etc/mu300/image-version)" $TAG_NOCARRY
for d in etc/openclash etc/adguardhome etc/smartdns etc/ssh; do if [ -d "$F/$d" ]; then echo "PASS kept /$d"; else echo "FAIL kept /$d"; fi; done
if grep -q MU300_UPDATE_KEEP=list "$F/etc/mu300/update-report" 2>/dev/null; then echo "PASS report fallback note"; else echo "FAIL report fallback note"; fi
