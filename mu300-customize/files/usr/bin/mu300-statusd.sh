#!/bin/sh
# 把 MU300 状态定期写进 /tmp/mu300-status.json(给 LuCI 页面读)
# 一次采集要 ~20 秒(AT 通道被数据面占着),而且 AT 打太频繁会把通道搞卡
# -> 间隔取 120 秒,并且不要再手工高频探测 AT
while :; do
  /usr/bin/mu300-status > /tmp/mu300-status.json.tmp 2>/dev/null && mv /tmp/mu300-status.json.tmp /tmp/mu300-status.json
  sleep 120
done