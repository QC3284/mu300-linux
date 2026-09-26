#!/bin/sh
# MU300 定时任务守护
#  读 /etc/mu300/schedule.json(页面直接写),每分钟检查一次到点没:
#    reboot -> 重启设备      wifi -> 重载无线(修客户端连不上的老毛病)
#  同一分钟内只执行一次;执行后把 last 写回去(页面能显示上次执行时间)
export PATH="$PATH:/opt/mu300/bin:/opt/mu300/busybox-bin"
DB=/etc/mu300/schedule.json
STAMP=/tmp/mu300-schedule.stamp

# 用 ucode 读配置并判断该不该执行(省得在 shell 里解析 JSON)
check() {
  ucode /usr/bin/mu300-schedule-check.uc
}

while :; do
  [ -f $DB ] || { sleep 30; continue; }
  action=$(check 2>/dev/null)
  case $action in
    reboot*)
      logger -t mu300-schedule "定时重启:$(echo $action | cut -d: -f2-)"
      sync
      sleep 2
      reboot
      ;;
    wifi*)
      logger -t mu300-schedule "定时重载无线"
      wifi reload >/dev/null 2>&1 || /sbin/wifi reload >/dev/null 2>&1
      ;;
  esac
  sleep 25
done