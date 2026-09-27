#!/bin/sh
# MU300 状态采集守护(四档 + 数据开关)
#   快  每 4 秒 :纯 sysfs//proc(速率/计数/时长/温度/WiFi/地址/CPU/内存) -> /tmp/mu300-live.json
#   中  每 20 秒:1 条 AT(CESQ)取信号                              -> /tmp/mu300-signal.json
#   中慢 每 60 秒:工程模式取服务小区+邻区(2 条 AT)                  -> /tmp/mu300-cells.json
#   慢  每 300 秒:其余 AT(制式/运营商/小区/频段/固件)               -> /tmp/mu300-status.json
# 另外负责:执行页面提交的"数据开关"请求(/tmp/mu300-net.req)
export PATH="$PATH:/opt/mu300/bin:/opt/mu300/busybox-bin"
# ---- 单实例锁(避免 restart 没杀干净导致重复采集/重复转发)----
LOCK=/var/run/mu300-statusd.lock
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    echo "mu300-statusd 已在运行 (pid $old),退出" >&2
    exit 0
  fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"; exit 0' TERM INT EXIT

t=0
while :; do
  # ---- 数据开关请求(对齐 UFI 的 7.1)----
  if [ -f /tmp/mu300-net.req ]; then
    act=$(tr -d ' \t\r\n' < /tmp/mu300-net.req 2>/dev/null)
    rm -f /tmp/mu300-net.req
    case "$act" in
      down) ( mobile-data down > /tmp/mu300-net.out 2>&1; echo "done down $(date +%s)" >> /tmp/mu300-net.out ) & ;;
      up)   ( # 只走 mobile-data up —— 【不要】再兜底 ifup wan ✗
              # 实测:ifup wan 会把刚起来的 sipa_eth0 重新打回 DOWN,反而更糟 ✗
              mobile-data up > /tmp/mu300-net.out 2>&1
              sleep 8
              if ! ip -4 addr show sipa_eth0 2>/dev/null | grep -q 'inet '; then
                echo "retry: mobile-data up" >> /tmp/mu300-net.out
                mobile-data up >> /tmp/mu300-net.out 2>&1
                sleep 6
              fi
              if ip -4 addr show sipa_eth0 2>/dev/null | grep -q 'inet '; then
                echo "done up $(date +%s) ok" >> /tmp/mu300-net.out
                exit 0
              fi
              # 仍然起不来 → 自愈:直接重启设备(开机流程一定会把数据面拉起来 ✓)
              # 实测:mobile-data down 之后 PDP 恢复不可靠 ✗,重启是唯一稳的路径 ✓
              echo "done up $(date +%s) FAILED -> auto reboot" >> /tmp/mu300-net.out
              sync
              sleep 1
              reboot ) & ;;
    esac
  fi
  # ---- 性能档切换请求(对齐 UFI 的"性能模式")----
  if [ -f /tmp/mu300-modes.req ]; then
    act=$(tr -d ' \t\r\n' < /tmp/mu300-modes.req 2>/dev/null)
    rm -f /tmp/mu300-modes.req
    case "$act" in
      profile\ eco|profile\ balanced|profile\ performance) /usr/bin/mu300-modes profile "${act#profile }" >/dev/null 2>&1 ;;  # 该命令自己会立刻回写 JSON
      apn*)     /usr/bin/mu300-modes apn "${act#apn:}" >/dev/null 2>&1; ifup wan >/dev/null 2>&1 & ;;
      5gran*)   /usr/bin/mu300-modes 5gran "${act#5gran:}" >/dev/null 2>&1 ;;
      speed*)   ( /usr/bin/mu300-speedtest > /tmp/mu300-speed.json.tmp 2>/dev/null && mv /tmp/mu300-speed.json.tmp /tmp/mu300-speed.json ) & ;;
      rat:*)    ( # 网络模式切换(实验性):
                  #   自动   = 打开 5G(AT+SP5GRAN=1),模组自行在 5G/4G/3G 间选择
                  #   仅4G   = 关闭 5G(AT+SP5GRAN=0)  ⚠ 实测这一步可能把模组搞到需要重启
                  # 切换后等 60 秒看数据有没有回来;没回来就【自动重启】恢复 ✓
                  mode="${act#rat:}"
                  case "$mode" in
                    auto) mu300-at -t 12 'AT+SP5GRAN=1' >/dev/null 2>&1 ;;
                    lte)  mu300-at -t 12 'AT+SP5GRAN=0' >/dev/null 2>&1 ;;
                  esac
                  sleep 30
                  ip -4 addr show sipa_eth0 2>/dev/null | grep -q 'inet ' && sleep 30
                  if ! ip -4 addr show sipa_eth0 2>/dev/null | grep -q 'inet '; then
                    echo "rat $mode: 数据没回来 -> auto reboot $(date +%s)" >> /tmp/mu300-net.out
                    sync; sleep 1; reboot
                  fi ) & ;;
    esac
  fi
  # ---- Ping 工具请求(对齐 UFI 的顶部 Ping)----
  # ---- 网页提交的锁频请求(/tmp/mu300-band.req: "nr 513 0 272 0 0")----
  if [ -f /tmp/mu300-band.req ]; then
    BL=$(tr -d ' \t\r\n' < /tmp/mu300-band.req 2>/dev/null)