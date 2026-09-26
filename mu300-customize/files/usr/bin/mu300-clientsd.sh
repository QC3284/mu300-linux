#!/bin/sh
# MU300 客户端管理守护
#  ① 每 30 秒采集客户端列表(DHCP 租约 + 无线站点 + 邻居表)-> /tmp/mu300-clients.json
#  ② 轮询 /tmp/mu300-clients.req:rename(备注名)/ kick(踢下线)/ static(静态绑定)/ refresh
export PATH="$PATH:/opt/mu300/bin:/opt/mu300/busybox-bin"
REQ=/tmp/mu300-clients.req
OUT=/tmp/mu300-clients.out
COLLECT=/usr/bin/mu300-clients-collect

reply() { { echo "TIME: $(date '+%Y-%m-%d %H:%M:%S')"; echo "ACTION: $1"; echo '---'; echo "$2"; } > $OUT; }

# 静态绑定:同一个 MAC 只保留一条(先删旧的再加)
set_static() {
  mac=$1; ip=$2; name=$3
  old=$(uci show dhcp 2>/dev/null | sed -n "s/^dhcp\.\(@host\[[0-9]*\]\)\.mac='$mac'/\1/p" | head -1)
  [ -n "$old" ] && uci delete "dhcp.$old" 2>/dev/null
  uci add dhcp host >/dev/null 2>&1
  uci set dhcp.@host[-1].mac="$mac"
  uci set dhcp.@host[-1].ip="$ip"
  [ -n "$name" ] && uci set dhcp.@host[-1].name="$name"
  uci commit dhcp
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
  echo "已绑定 $mac -> $ip(客户端下次续租生效)"
}

$COLLECT >/dev/null 2>&1
tick=0
while :; do
  if [ -s $REQ ]; then
    action=''; mac=''; name=''; ip=''
    while IFS='=' read -r k v; do
      case $k in
        action) action=$v ;;
        mac) mac=$v ;;
        name) name=$v ;;
        ip) ip=$v ;;
      esac
    done < $REQ
    rm -f $REQ
    case $action in
      rename)
        r=$(/usr/bin/mu300-clients-rename "$mac" "$name" 2>&1)
        reply rename "$r" ;;
      kick)
        if iw dev wlan0 station del "$mac" 2>/tmp/kick.err; then
          reply kick "已断开 $mac(无线客户端)"
        else
          reply kick "断开失败:$(head -1 /tmp/kick.err 2>/dev/null)(有线设备不会被 deauth,可拔网线或等它的 DHCP 租约过期)"
        fi ;;
      static)
        if [ -n "$mac" ] && [ -n "$ip" ]; then
          reply static "$(set_static "$mac" "$ip" "$name")"
        else
          reply static '参数不完整(需要 mac 和 ip)'
        fi ;;
      refresh)
        reply refresh '已刷新' ;;
      *) reply '?' "未知动作: $action" ;;
    esac
    $COLLECT >/dev/null 2>&1
  fi
  tick=$((tick+1))
  [ $((tick % 30)) -eq 0 ] && $COLLECT >/dev/null 2>&1
  sleep 1
done