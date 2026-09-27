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
    esac
  fi
  # ---- Ping 工具请求(对齐 UFI 的顶部 Ping)----
  if [ -f /tmp/mu300-tools.req ]; then
    req=$(tr -d ' \t\r\n' < /tmp/mu300-tools.req 2>/dev/null)
    rm -f /tmp/mu300-tools.req
    case "$req" in
      ping:*) ( # 只允许字母数字和 . : - _(防注入 ✓)
               host=$(printf '%s' "${req#ping:}" | tr -cd 'A-Za-z0-9.:_-')
               { echo "TIME: $(date '+%F %T')"; echo "TARGET: $host"; echo '---';
                 [ -n "$host" ] && ping -c 4 -W 3 "$host" 2>&1 || echo "主机名非法"; } > /tmp/mu300-tools.out ) & ;;
    esac
  fi
  /usr/bin/mu300-status-live > /tmp/mu300-live.json.tmp 2>/dev/null && mv /tmp/mu300-live.json.tmp /tmp/mu300-live.json
  t=$((t+1))
  if [ $((t % 5)) -eq 1 ]; then
    /usr/bin/mu300-status-signal > /tmp/mu300-signal.json.tmp 2>/dev/null && mv /tmp/mu300-signal.json.tmp /tmp/mu300-signal.json
  fi
  if [ $((t % 15)) -eq 1 ]; then
    /usr/bin/mu300-cells > /tmp/mu300-cells.json.tmp 2>/dev/null && mv /tmp/mu300-cells.json.tmp /tmp/mu300-cells.json
  fi
  # 模式/CPU 很轻(纯 sysfs + 1 条 AT),30 秒一采,切档后更快反映
  if [ $((t % 8)) -eq 1 ]; then
    /usr/bin/mu300-modes > /tmp/mu300-modes.json.tmp 2>/dev/null && mv /tmp/mu300-modes.json.tmp /tmp/mu300-modes.json
  fi
  if [ $((t % 45)) -eq 1 ]; then
    /usr/bin/mu300-status > /tmp/mu300-status.json.tmp 2>/dev/null && mv /tmp/mu300-status.json.tmp /tmp/mu300-status.json
  fi
  sleep 4
done