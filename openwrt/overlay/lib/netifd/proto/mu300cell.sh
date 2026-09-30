#!/bin/sh
# netifd protocol for the MU300 modem: attach with AT commands (mobile-data) and configure sipa_eth0.
# /etc/config/network:  config interface 'wan' / option proto 'mu300cell' / option apn 'internet'
# LuCI edits the same options through www/luci-static/resources/protocol/mu300cell.js.
[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_mu300cell_init_config() {
	available=1
	no_device=1
	proto_config_add_string "apn"
	proto_config_add_string "pdptype"
	proto_config_add_boolean "peerdns"
	proto_config_add_array "dns:list(ipaddr)"
}

proto_mu300cell_setup() {
	local config="$1"
	local apn pdptype peerdns out ifname ip prefix dns1 dns2
	json_get_vars apn pdptype peerdns

	# SIPA 竞态修复:冷启动 CP 可能未就绪。先等 CP(最多 120s),再退避重试 3 次;
	# 只有全部 rc=3 才认定真的没有调制解调器。
	. /opt/mu300/bin/wait-cp 2>/dev/null || true
	command -v wait_cp >/dev/null 2>&1 || wait_cp() { :; }
	wait_cp 120 3 || true
	rc=3
	attempt=0
	while [ "$attempt" -lt 3 ]; do
		out=$(MU300_NETIFD=1 MU300_PDP_TYPE="${pdptype:-IP}" /opt/mu300/bin/mobile-data up $apn 2>/tmp/mu300cell.err)
		rc=$?
		[ "$rc" = 0 ] && break
		[ "$rc" = 3 ] || break
		attempt=$((attempt + 1))
		logger -t mu300cell "no modem (attempt $attempt/3), retrying in 10s"
		sleep 10
	done
	if [ "$rc" = 3 ]; then
		logger -t mu300cell "NO_MODEM(前400字符): $(cut -c1-400 /tmp/mu300cell.err | tr '\n' ' ')"
		proto_notify_error "$config" NO_MODEM
		proto_block_restart "$config"
		return 1
	fi
	ip=$(echo "$out" | sed -n 's/^IP=//p')
	if [ -z "$ip" ]; then
		logger -t mu300cell "attach failed(前400字符): $(cut -c1-400 /tmp/mu300cell.err | tr '\n' ' ')"
		proto_notify_error "$config" ATTACH_FAILED
		sleep 20
		proto_setup_failed "$config"
		return 1
	fi
	ifname=$(echo "$out" | sed -n 's/^IFACE=//p')
	prefix=$(echo "$out" | sed -n 's/^PREFIX=//p')
	dns1=$(echo "$out" | sed -n 's/^DNS1=//p')
	dns2=$(echo "$out" | sed -n 's/^DNS2=//p')

	ip link set "$ifname" up
	proto_init_update "$ifname" 1
	proto_add_ipv4_address "$ip" "${prefix:-32}"
	proto_add_ipv4_route "0.0.0.0" 0
	if [ "${peerdns:-1}" != 0 ]; then
		[ -n "$dns1" ] && proto_add_dns_server "$dns1"
		[ -n "$dns2" ] && proto_add_dns_server "$dns2"
	fi
	proto_send_update "$config"
	# After proto_send_update, not before: netifd turns IPv6 back on as it configures the interface, so
	# mobile-data setting this itself has no effect on OpenWrt. The bearer is IPv4-only (the context is
	# "IP", the way Android's RIL asks for it), and an interface left with a link-local address sends
	# router solicitations and multicast into it for nothing. See docs/FINDINGS.md 13f.
	[ "${pdptype:-IP}" = IP ] && [ -w "/proc/sys/net/ipv6/conf/$ifname/disable_ipv6" ] &&
		echo 1 > "/proc/sys/net/ipv6/conf/$ifname/disable_ipv6"
	[ -w /sys/class/leds/sc27xx:blue/brightness ] && echo 255 > /sys/class/leds/sc27xx:blue/brightness
	logger -t mu300cell "connected: $ip/${prefix:-32} on $ifname"
}

proto_mu300cell_teardown() {
	local config="$1"
	/opt/mu300/bin/mobile-data down >/dev/null 2>&1
	proto_kill_command "$config"
}

[ -n "$INCLUDE_ONLY" ] || add_protocol mu300cell
