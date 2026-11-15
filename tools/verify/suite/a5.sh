#!/bin/sh
. /tmp/suite-env.sh
set -u
# nothing may go to the network in here: the device cases are about local files
export MU300_RELEASE_URL=http://127.0.0.1:1/r MU300_API_URL=http://127.0.0.1:1 MU300_FETCH_DELAY=0 MU300_FETCH_RETRIES=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: [$2] != [$3]"; fi; }
reset() { rm -rf /mnt/mu300-disk/openwrt /mnt/mu300-disk/openwrt.old /mnt/mu300-disk/openwrt.new; cp -a /opt/old-base /mnt/mu300-disk/openwrt; }
loadup() { MU300_LIB=1; export MU300_LIB; . /tmp/newimg/opt/mu300/bin/mu300-update; MU300_DISK=/mnt/mu300-disk; STAGE=/tmp/stage; export MU300_DISK STAGE; }
echo "== A5 geo: a package data file the user replaced is kept"
reset; loadup
cp /tmp/stage/rootfs.tar.gz /tmp/stage/mu300-immortalwrt-rootfs.tar.gz
( apply_one openwrt $TAG_NEW ) >/tmp/geo.out 2>/tmp/geo.err; echo "positive_rc=$?"
echo "positive_err=$(tail -n 3 /tmp/geo.err | tr "\\n" "|")"
NEW=/mnt/mu300-disk/openwrt
KEEP=$NEW/etc/mu300/update-kept/$TAG_OLD/user
ok geo_user "$(sha256sum $KEEP/etc/openclash/GeoSite.dat 2>/dev/null | cut -d" " -f1)" "$(cat /tmp/expected_geo_user.sha)"
ok mmdb_user "$(sha256sum $KEEP/etc/openclash/Country.mmdb 2>/dev/null | cut -d" " -f1)" "$(cat /tmp/expected_mmdb_user.sha)"
if grep -q GeoSite.dat "$NEW/etc/mu300/update-report" 2>/dev/null; then echo "PASS report names GeoSite.dat"; else echo "FAIL report geo"; fi
