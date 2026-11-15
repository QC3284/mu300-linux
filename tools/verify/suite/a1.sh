#!/bin/sh
. /tmp/suite-env.sh
set -u
# nothing may go to the network in here: the device cases are about local files
export MU300_RELEASE_URL=http://127.0.0.1:1/r MU300_API_URL=http://127.0.0.1:1 MU300_FETCH_DELAY=0 MU300_FETCH_RETRIES=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: [$2] != [$3]"; fi; }
reset() { rm -rf /mnt/mu300-disk/openwrt /mnt/mu300-disk/openwrt.old /mnt/mu300-disk/openwrt.new; cp -a /opt/old-base /mnt/mu300-disk/openwrt; }
loadup() { MU300_LIB=1; export MU300_LIB; . /tmp/newimg/opt/mu300/bin/mu300-update; MU300_DISK=/mnt/mu300-disk; STAGE=/tmp/stage; export MU300_DISK STAGE; }
echo "== A1 carry: a user file of a package over the update"
reset; loadup
if carry_ready /tmp/newimg; then echo "PASS carry_ready YES"; else echo "FAIL carry_ready"; fi
NEW=/mnt/mu300-disk/openwrt
echo "old_version=$(cat $NEW/etc/mu300/image-version)"
cp /tmp/stage/rootfs.tar.gz /tmp/stage/mu300-immortalwrt-rootfs.tar.gz
( apply_one openwrt $TAG_NEW ) >/tmp/pos.out 2>/tmp/pos.err; echo "positive_rc=$?"
echo "positive_err=$(tail -n 3 /tmp/pos.err | tr "\\n" "|")"
ok new_version "$(cat $NEW/etc/mu300/image-version)" $TAG_NEW
for f in etc/openclash/config/config.yaml etc/openclash/custom/mine.yaml etc/openclash/proxy_provider/Provider_C54978.yaml etc/adguardhome/adguardhome.yaml etc/adguardhome/data/querylog.json etc/smartdns/custom.conf etc/smartdns/conf.d/mine.conf etc/sysupgrade.conf etc/msmtprc etc/ssl/private/mine.pem root/mine.txt; do
  if [ -f "$NEW/$f" ]; then echo "PASS carried /$f"; else echo "FAIL carried /$f"; fi
done
if grep -q HostKey "$NEW/etc/ssh/sshd_config"; then echo "PASS carried sshd_config"; else echo "FAIL sshd_config"; fi
if grep -q "user line" "$NEW/etc/hosts"; then echo "PASS carried hosts user line"; else echo "FAIL hosts"; fi
if grep -q aurora-font.css "$NEW/etc/mu300/update-report" 2>/dev/null; then echo "PASS report names set-aside file"; else echo "FAIL report collision"; fi
KP=$(find "$NEW/etc/mu300/update-kept" -name openclash_custom_rules.list -type f 2>/dev/null | head -n 1)
ok kept_user "$(sha256sum "$KP" 2>/dev/null | cut -d" " -f1)" "$(cat /tmp/expected_rules_user.sha)"
if [ -e "$NEW/etc/openclash/custom/openclash_custom_rules.list" ]; then echo "INFO place still has a file"; else echo "PASS place free for install"; fi
if grep -qx "luci-app-openclash	etc/openclash/custom/openclash_custom_rules.list" "$NEW/etc/mu300/user-packages/package-files" 2>/dev/null; then echo "PASS package-files names file"; else echo "FAIL package-files"; fi
if grep -q "Files of packages you changed" "$NEW/etc/mu300/update-report" 2>/dev/null; then echo "PASS report j list"; else echo "FAIL report j"; fi
if grep -q "are kept as yours" "$NEW/etc/mu300/update-report" 2>/dev/null; then echo "PASS report count"; else echo "FAIL report count"; fi
if grep -q "files of packages are not carried" "$NEW/etc/mu300/update-report" 2>/dev/null; then echo "PASS report npkg"; else echo "FAIL report npkg"; fi
