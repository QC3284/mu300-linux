#!/bin/sh
. /tmp/suite-env.sh
set -u
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: [$2] != [$3]"; fi; }
echo "== B2 first boot: the package installs its default, then the user file is put back"
NB=/tmp/t/bin; mkdir -p $NB /tmp/t
printf "%s\n" "#!/bin/sh" "case \$1 in" "  update) exit 0 ;;" "  info) exit 1 ;;" "  add) shift; for p in \"\$@\"; do case \$p in luci-app-openclash) mkdir -p /etc/openclash/custom; printf \"# openclash default rules\\nRULE-SET,reject\\nGEOIP,CN,DIRECT\\n\" > /etc/openclash/custom/openclash_custom_rules.list ;; esac; done; exit 0 ;;" "esac" "exit 0" > $NB/apk
chmod 755 $NB/apk
PATH=$NB:/opt/mu300/bin:/usr/sbin:/sbin:/usr/bin:/bin; export PATH
MU300_PKG_SETTLE=0 MU300_PKG_DELAY=0 MU300_PKG_TRIES=1 MU300_DNS_CHECKS=1 MU300_DNS_INTERVAL=0; export MU300_PKG_SETTLE MU300_PKG_DELAY MU300_PKG_TRIES MU300_DNS_CHECKS MU300_DNS_INTERVAL
/opt/mu300/bin/mu300-user-packages run >/tmp/t/run.out 2>/tmp/t/run.err; echo "run_rc=$?"
echo "run_out=$(tail -n 6 /tmp/t/run.out | tr "\\n" "|")"
check restored_user "$(sha256sum /etc/openclash/custom/openclash_custom_rules.list 2>/dev/null | cut -d" " -f1)" "$(cat /tmp/expected_rules_user.sha)"
if [ -e /etc/mu300/update-kept/$TAG_OLD/user/etc/openclash/custom/openclash_custom_rules.list ]; then echo "FAIL kept copy still there"; else echo "PASS kept copy moved back"; fi
if grep -q "is back" /etc/mu300/user-packages/log 2>/dev/null; then echo "PASS log says it is back"; else echo "FAIL log"; fi
echo "state=$(cat /etc/mu300/user-packages/state 2>/dev/null)"
