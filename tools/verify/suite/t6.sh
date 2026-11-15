#!/bin/sh
. /tmp/suite-env.sh
# repair-dns with the update-kept tree present: the .3 binary (bug) leaves the forwarder, the .4 binary removes it
set -u
NEWBIN=/opt/mu300/bin/mu300-user-packages
OLDBIN=/tmp/upk-old-binary
NB=/tmp/t/bin
mkdir -p "$NB" /tmp/t
cat > "$NB/apk" <<'EOF'
#!/bin/sh
case $1 in
  update) exit 0 ;;
  info) exit 1 ;;
  add) exit 1 ;;   # not in the feeds: failed for good
esac
exit 0
EOF
chmod 755 "$NB/apk"
PATH="$NB:/opt/mu300/bin:/usr/sbin:/sbin:/usr/bin:/bin"; export PATH
MU300_PKG_TRIES=1 MU300_PKG_DELAY=0 MU300_PKG_SETTLE=0 MU300_DNS_CHECKS=1 MU300_DNS_INTERVAL=0
export MU300_PKG_TRIES MU300_PKG_DELAY MU300_PKG_SETTLE MU300_DNS_CHECKS MU300_DNS_INTERVAL
echo "old_binary_sha=$(sha256sum $OLDBIN | cut -d' ' -f1)"
echo "new_binary_sha=$(sha256sum $NEWBIN | cut -d' ' -f1)"
setup() {
  rm -rf /etc/mu300/update-kept /etc/mu300/orphaned-config /etc/mu300/user-packages
  mkdir -p /etc/mu300/user-packages /etc/mu300/orphaned-config/etc/config
  mkdir -p /etc/mu300/update-kept/$TAG_OLD/user/etc/openclash/custom
  echo luci-app-openclash > /etc/mu300/user-packages/wanted
  printf '%s\t%s\n' luci-app-openclash etc/config/openclash > /etc/mu300/user-packages/files
  printf "config openclash 'main'\n\tlist proxy_port '7874'\n" > /etc/mu300/orphaned-config/etc/config/openclash
  printf "# the rules of the user\nREDIRECT,127.0.0.1#7874\n" > /etc/mu300/update-kept/$TAG_OLD/user/etc/openclash/custom/openclash_custom_rules.list
  rm -f /etc/mu300/user-packages/state /etc/mu300/user-packages/failed /etc/mu300/user-packages/log /etc/mu300/user-packages/dns-note
  uci -q delete dhcp.@dnsmasq[0].server
  uci -q add_list dhcp.@dnsmasq[0].server='127.0.0.1#7874'
  uci -q add_list dhcp.@dnsmasq[0].server='8.8.8.8'
  uci -q set dhcp.@dnsmasq[0].noresolv='1'
  uci -q commit dhcp
}
servers() { uci -q get dhcp.@dnsmasq[0].server | tr "\n" " "; }
run_case() {
  label=$1; bin=$2
  echo "== case $label"
  setup
  "$bin" run >/tmp/t/run.out 2>/tmp/t/run.err; echo "run_rc=$?"
  echo "servers_after_run=$(servers)"
  echo "log=$(tr "\n" "|" < /etc/mu300/user-packages/log 2>/dev/null | tail -c 500)"
  case $label in
    old) if (uci -q get dhcp.@dnsmasq[0].server | grep -q '7874'); then echo "PASS old binary reproduces the bug: forwarder not removed"; else echo "FAIL old binary unexpectedly removed it"; fi ;;
    new) if (uci -q get dhcp.@dnsmasq[0].server | grep -q '7874'); then echo "FAIL new binary left the forwarder"; else echo "PASS new binary removed the forwarder with update-kept present"; fi ;;
  esac
}
echo "== case repair-dns (only forwarder, new binary)"
setup
uci -q delete dhcp.@dnsmasq[0].server
uci -q add_list dhcp.@dnsmasq[0].server='127.0.0.1#7874'
uci -q commit dhcp
"$NEWBIN" run >/tmp/t/rr.out 2>/tmp/t/rr.err; echo "run_rc=$?"
echo "servers_after_run=$(servers)"
"$NEWBIN" repair-dns >/tmp/t/rd.out 2>/tmp/t/rd.err; echo "repairdns_rc=$?"
echo "repairdns_out=$(tail -n 3 /tmp/t/rd.out | tr "\n" "|")"
echo "repairdns_err=$(tail -n 3 /tmp/t/rd.err | tr "\n" "|")"
echo "servers_after_repair=$(servers)"
echo "noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv)"
echo "dhcp_before_copy=$(test -f /etc/mu300/orphaned-config/etc/config/dhcp.before-dns-repair && echo yes || echo no)"
if (uci -q get dhcp.@dnsmasq[0].server | grep -q '7874'); then echo "FAIL repair-dns left the only forwarder"; else echo "PASS repair-dns removed the only forwarder"; fi
if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = "0" ]; then echo "PASS noresolv 0 (the resolvers answer)"; else echo "FAIL noresolv"; fi
run_case old "$OLDBIN"
run_case new "$NEWBIN"
echo DONE
