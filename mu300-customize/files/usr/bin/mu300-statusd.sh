#!/bin/sh
# MU300 状态采集守护(三档)
#   快  每 4 秒 :纯 sysfs(速率/计数/在线时长/温度/WiFi/地址)   -> /tmp/mu300-live.json
#   中  每 20 秒:1 条 AT(CESQ)取信号                         -> /tmp/mu300-signal.json
#   慢  每 300 秒:其余 AT(制式/运营商/小区/频段/固件)          -> /tmp/mu300-status.json
# 为什么分档:AT 查询一条要几秒,打太勤会把通道搞卡(踩过坑);
#            但信号是用户最想看"会动"的数据,所以单独拆出来勤采
t=0
while :; do
  /usr/bin/mu300-status-live > /tmp/mu300-live.json.tmp 2>/dev/null && mv /tmp/mu300-live.json.tmp /tmp/mu300-live.json
  t=$((t+1))
  if [ $((t % 5)) -eq 1 ]; then
    /usr/bin/mu300-status-signal > /tmp/mu300-signal.json.tmp 2>/dev/null && mv /tmp/mu300-signal.json.tmp /tmp/mu300-signal.json
  fi
  if [ $((t % 75)) -eq 1 ]; then
    /usr/bin/mu300-status > /tmp/mu300-status.json.tmp 2>/dev/null && mv /tmp/mu300-status.json.tmp /tmp/mu300-status.json
  fi
  sleep 4
done