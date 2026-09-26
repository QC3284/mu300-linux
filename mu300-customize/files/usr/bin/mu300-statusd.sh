#!/bin/sh
# MU300 状态采集守护(两档频率)
#   快档:每 5 秒跑 mu300-status-live(纯 sysfs,~1 秒)   -> /tmp/mu300-live.json
#   慢档:每 90 秒跑 mu300-status(要走 AT,~20 秒)        -> /tmp/mu300-status.json(信号/制式/频段等)
# 为什么分开:AT 查询一次要好几秒,而且打太勤会把 AT 通道搞卡(踩过坑)
while :; do
  /usr/bin/mu300-status-live > /tmp/mu300-live.json.tmp 2>/dev/null && mv /tmp/mu300-live.json.tmp /tmp/mu300-live.json
  n=$((n+1))
  if [ $((n % 18)) -eq 1 ]; then
    /usr/bin/mu300-status > /tmp/mu300-status.json.tmp 2>/dev/null && mv /tmp/mu300-status.json.tmp /tmp/mu300-status.json
  fi
  sleep 4
done