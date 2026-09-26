#!/bin/sh
# MU300 IPv6 透传(全球前缀 + NDP 代理),替代 NAT66:
#  1) 从 WAN(sipa_eth0)取运营商 /64,配到 br-lan 上(前缀变化自动跟随)
#  2) 开 proxy_ndp,把 br-lan 上客户端的全球地址登记为 WAN 口上的代理条目
#     —— 运营商的路由器(fe80::2)来问客户端地址时,由我们代答,实现真透传
#  3) 清理过期条目
WAN=sipa_eth0
LAN=br-lan
PROXY_DEV=$WAN
INTERVAL=${V6_INTERVAL:-10}

log() { logger -t mu300-v6 '$*'; }

wan_prefix() {
  # 取形如 2408:8421:b113:47cb:xxxx:xxxx:xxxx:xxxx/64 的前 4 段
  ip -6 addr show $WAN 2>/dev/null | awk '/scope global/ {print $2}' | head -1 | \
    sed 's#/[0-9]*$##' | awk -F: '{print $1":"$2":"$3":"$4}'
}

ensure_lan_addr() {
  p=$1
  [ -n "$p" ] || return 0
  want="$p::1/64"
  cur=$(ip -6 addr show dev $LAN | awk '/scope global/ {print $2}' | grep -v '^fd' | head -1)
  [ "$cur" = "$want" ] && return 0
  [ -n "$cur" ] && ip -6 addr del "$cur" dev $LAN 2>/dev/null
  ip -6 addr add "$want" dev $LAN 2>/dev/null && log "br-lan 换用新前缀 $want"
}

sync_proxies() {
  p=$1
  [ -n "$p" ] || return 0
  # 当前客户端全球地址(br-lan 邻居表里属于运营商 /64 的)
  cur=$(ip -6 neigh show dev $LAN 2>/dev/null | awk '/^24/ {print $1}' | grep -v '^fd')
  # 已登记的代理条目
  have=$(ip -6 neigh show proxy dev $PROXY_DEV 2>/dev/null | awk '{print $1}')
  for a in $cur; do
    echo "$have" | grep -qx "$a" || { ip -6 neigh add proxy "$a" dev $PROXY_DEV 2>/dev/null && log "代理 + $a"; }
  done
  for a in $have; do
    echo "$cur" | grep -qx "$a" || { ip -6 neigh del proxy "$a" dev $PROXY_DEV 2>/dev/null && log "代理 - $a"; }
  done
}

sysctl -qw net.ipv6.conf.$PROXY_DEV.proxy_ndp=1 2>/dev/null
sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null

while :; do
  p=$(wan_prefix)
  if [ -n "$p" ]; then
    ensure_lan_addr "$p"
    sync_proxies "$p"
  fi
  sleep $INTERVAL
done