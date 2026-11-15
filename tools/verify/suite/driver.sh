#!/bin/sh
set -u
. /tmp/suite-env.sh
export TAG_NEW TAG_OLD TAG_NOCARRY
echo "IMAGE=$(cat /etc/mu300/image-version)"
echo "UPDATER=$(sha256sum /opt/mu300/bin/mu300-update | cut -d" " -f1)"
cp /tmp/stage/mu300-immortalwrt-rootfs.tar.gz /tmp/stage/rootfs.tar.gz
sh /tmp/t/a1.sh
NEWROOT=/mnt/mu300-disk/openwrt
rm -rf $NEWROOT/tmp/t; cp -a /tmp/t $NEWROOT/tmp/t
cp /tmp/suite-env.sh $NEWROOT/tmp/suite-env.sh
cp /tmp/upk-old-binary $NEWROOT/tmp/upk-old-binary
cp /tmp/expected_rules_user.sha /tmp/expected_geo_user.sha /tmp/expected_mmdb_user.sha $NEWROOT/tmp/
echo "== first boot of the new system"
chroot $NEWROOT /bin/sh /tmp/t/t2.sh
sh /tmp/t/a3.sh
sh /tmp/t/a4.sh
sh /tmp/t/a5.sh
NEWROOT=/mnt/mu300-disk/openwrt
rm -rf $NEWROOT/tmp/t; cp -a /tmp/t $NEWROOT/tmp/t
cp /tmp/suite-env.sh $NEWROOT/tmp/suite-env.sh
cp /tmp/upk-old-binary $NEWROOT/tmp/upk-old-binary
echo "== repair cases in the new system"
chroot $NEWROOT /bin/sh /tmp/t/t6.sh
echo ALLDONE
