#!/bin/bash
# ============================================================================
# MU300 / ZTE F50 Linux 定制一键安装(幂等 —— 可以反复跑)
#
# 用途:刷完新的 rootfs 之后,把这一整套自研功能恢复回来:
#   数据灯 / 状态采集 / 流量统计 / AT 控制台 / IPv6 透传 / LuCI 三个页面
#   + 必须的配置修正(flow_offloading=0、MTU 1432、DHCP 池与租期、换 apk 镜像)
#
# 用法:  bash install.sh                 # 默认 root@192.168.77.1
#        HOST=root@192.168.5.9 bash install.sh
#
# 安全:只写 /usr/bin /etc/init.d /etc/hotplug.d /www /usr/share/{luci,rpcd} /etc/config
#       不碰任何分区 / bootloader / 内核
# ============================================================================
set -u
HOST=${HOST:-root@192.168.77.1}
HERE=$(cd "$(dirname "$0")" && pwd)
PW=${PW:-CHANGE_ME}

if [ -n "$PW" ]; then
  printf '#!/bin/sh\necho %s\n' "$PW" > /tmp/.mu300-askpass; chmod 700 /tmp/.mu300-askpass
  export DISPLAY=:0 SSH_ASKPASS=/tmp/.mu300-askpass SSH_ASKPASS_REQUIRE=force
  SSH_OPTS="-o PreferredAuthentications=password -o PubkeyAuthentication=no"
else
  SSH_OPTS=""
fi
ssh_() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 $SSH_OPTS "$HOST" "$@"; }

echo '=== 1/5 推送文件 ==='
( cd "$HERE/files" && tar czf - . ) | ssh_ 'tar xzf - -C / && echo "  文件已解包"'
ssh_ 'chmod 755 /usr/bin/mu300-* /etc/init.d/mu300-* 2>/dev/null; echo "  权限已设置"'

echo '=== 2/5 应用 uci 配置(必须项)==='
ssh_ '
  # ① 厂商内核没有 flowtable,必须关掉硬件/软件 flow offloading,否则规则集报错、WAN 未绑定 -> 没 NAT
  uci set firewall.@defaults[0].flow_offloading=0
  uci set firewall.@defaults[0].flow_offloading_hw=0
  # ② DHCP 池/租期(与用户主路由一致)
  uci set dhcp.lan.start=100
  uci set dhcp.lan.limit=254
  uci set dhcp.lan.leasetime=24h
  # ③ 不要过滤 AAAA(我们要给客户端真 IPv6)
  uci set dhcp.@dnsmasq[0].filter_aaaa=0 2>/dev/null || true
  # ④ WAN MTU:运营商 RA 下发 1432,接口默认 1500 -> 大包被丢、下载中途卡死
  uci set network.wan.mtu=1432
  uci commit
  echo "  已写入并提交"'

echo '=== 3/5 换 apk 镜像(SJTU 太慢 -> 南大)==='
ssh_ '
  [ -d /etc/apk/repositories.d.bak ] || cp -r /etc/apk/repositories.d /etc/apk/repositories.d.bak 2>/dev/null
  sed -i "s#mirror\.sjtu\.edu\.cn#mirror.nju.edu.cn#g" /etc/apk/repositories.d/*.list 2>/dev/null
  echo "  当前源: $(grep -h -m1 -v \"^#\" /etc/apk/repositories.d/*.list | head -c 80)"'

echo '=== 4/5 启用并启动五个守护 ==='
for s in mu300-led mu300-statusd mu300-trafd mu300-atweb mu300-v6-relay; do
  ssh_ "/etc/init.d/$s enable >/dev/null 2>&1; /etc/init.d/$s restart >/dev/null 2>&1; \",
       "n=\$(ps w | grep -c \"[m]u300-$(echo $s | sed 's/^mu300-//').sh\"); echo \"  $s -> 实例 \$n\"" 2>/dev/null || echo "  $s -> 启动失败(检查)"
done

echo '=== 5/5 重启受影响的系统服务 ==='
ssh_ '/etc/init.d/firewall restart >/dev/null 2>&1; /etc/init.d/dnsmasq restart >/dev/null 2>&1;
      /etc/init.d/rpcd restart >/dev/null 2>&1; /etc/init.d/uhttpd restart >/dev/null 2>&1;
      rm -f /tmp/luci-indexcache*; echo "  已重启 firewall/dnsmasq/rpcd/uhttpd"'

echo
echo '=== 验证 ==='
ssh_ '
  echo "  flow_offloading = $(uci get firewall.@defaults[0].flow_offloading)  (必须 0)"
  echo "  MTU             = $(cat /sys/class/net/sipa_eth0/mtu 2>/dev/null)  (应为 1432)"
  echo "  守护            = led:$(pidof mu300-led.sh | wc -w) statusd:$(pidof mu300-statusd.sh | wc -w) trafd:$(pidof mu300-trafd.sh | wc -w) atweb:$(pidof mu300-atweb.sh | wc -w) v6:$(pidof mu300-v6-relay.sh | wc -w)"
  echo "  LuCI 页面       = $(ls /www/luci-static/resources/view/mu300/ 2>/dev/null | wc -l) 个"
  echo "  NAT 规则        = $(nft list ruleset 2>/dev/null | grep -c sipa_eth0) 处引用 sipa_eth0"'
echo
echo '完成。浏览器里注销重登一次,然后看 网络 -> MU300 5G。'