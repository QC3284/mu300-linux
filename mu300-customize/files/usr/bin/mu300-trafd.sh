#!/bin/sh
# MU300 流量统计:每 30 秒采一次 WAN 计数,按天累计
#  - /etc/mu300/traffic.json  持久化(重启不丢)
#  - /tmp/mu300-traffic.json  给 LuCI 页面读的快照
WAN=sipa_eth0
DB=/etc/mu300/traffic.json
LIVE=/tmp/mu300-traffic.json
KEEP_DAYS=40

read_counters() {
  rx=$(cat /sys/class/net/$WAN/statistics/rx_bytes 2>/dev/null || echo 0)
  tx=$(cat /sys/class/net/$WAN/statistics/tx_bytes 2>/dev/null || echo 0)
}

while :; do
  read_counters
  today=$(date +%Y-%m-%d)
  now=$(date +%s)
  # 用 awk 解析/更新 JSON(ucode 不在这里用,保持纯 busybox 依赖)
  awk -v today="$today" -v rx="$rx" -v tx="$tx" -v now="$now" -v keep="$KEEP_DAYS" '
    function jnum(s) { gsub(/[^0-9]/,"",s); return s+0 }
    BEGIN { day_rx=0; day_tx=0; last_rx=0; last_tx=0; n=0 }
    {
      line=$0
      if (match(line, /"last_rx": *[0-9]+/)) { s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); last_rx=s+0 }
      if (match(line, /"last_tx": *[0-9]+/)) { s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); last_tx=s+0 }
      if (match(line, /"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]": *\{/)) {
        d=substr(line,RSTART+1,10)
        days[d]=1
        if (match(line, /"rx": *[0-9]+/)) { s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); drx[d]=s+0 }
        if (match(line, /"tx": *[0-9]+/)) { s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); dtx[d]=s+0 }
      }
    }
    END {
      dr = rx - last_rx; dt = tx - last_tx
      if (dr < 0 || dt < 0) { dr = 0; dt = 0 }   # 计数器被重置(重启/重连)时丢弃这一跳
      drx[today] += dr; dtx[today] += dt; days[today]=1
      printf "{\n  \"last_rx\": %d,\n  \"last_tx\": %d,\n  \"updated\": %d,\n  \"today\": \"%s\",\n  \"days\": {\n", rx, tx, now, today
      first=1
      for (d in days) {
        if (!first) printf ",\n"
        printf "    \"%s\": { \"rx\": %d, \"tx\": %d }", d, drx[d]+0, dtx[d]+0
        first=0
      }
      printf "\n  }\n}\n"
    }
  ' $DB 2>/dev/null > $DB.tmp && mv $DB.tmp $DB
  cp $DB $LIVE 2>/dev/null
  sleep 30
done