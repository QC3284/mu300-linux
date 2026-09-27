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

  # ---- 网页提交的写操作请求 ----
  if [ -f /tmp/mu300-band.req ]; then
    BL=$(head -1 /tmp/mu300-band.req 2>/dev/null)
    rm -f /tmp/mu300-band.req
    set -- $BL
    TYP=$1
    shift
    if [ -n "$TYP" ] && [ $# -ge 5 ]; then
      mu300-band write "$1" "$2" "$3" "$4" "$5" >/dev/null 2>&1
      echo "bandlock $TYP $1 $2 $3 $4 $5" >>/tmp/ufi-bandlock.log
    fi
  fi
  if [ -f /tmp/mu300-celllock.req ]; then
    CL=$(head -1 /tmp/mu300-celllock.req 2>/dev/null)
    rm -f /tmp/mu300-celllock.req
    set -- $CL
    A1="$1"; A2="$2"; A3="$3"
    if [ "$A1" = "unlock" ]; then
      RAT="$A2"
      [ -z "$RAT" ] && RAT=16
      mu300-at -t 12 "AT+SPFORCEFRQ=$RAT,0" >/dev/null 2>&1
      rm -f /etc/mu300/celllock.json
      echo "celllock unlock rat=$RAT" >>/tmp/ufi-celllock.log
    elif [ -n "$A1" ] && [ -n "$A2" ] && [ -n "$A3" ]; then
      mu300-at -t 12 "AT+SPFORCEFRQ=$A1,1,$A2,$A3" >/dev/null 2>&1
      echo celllock ok > /etc/mu300/celllock.json
      echo "celllock lock rat=$A1 earfcn=$A2 pci=$A3" >>/tmp/ufi-celllock.log
    fi
  fi
  # ---- 数据开关请求(对齐 UFI 的 7.1)----
  if [ -f /tmp/mu300-net.req ]; then
    act=$(head -1 /tmp/mu300-net.req 2>/dev/null)
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
    act=$(head -1 /tmp/mu300-modes.req 2>/dev/null)
    rm -f /tmp/mu300-modes.req
    case "$act" in
      profile\ eco|profile\ balanced|profile\ performance) /usr/bin/mu300-modes profile "${act#profile }" >/dev/null 2>&1 ;;  # 该命令自己会立刻回写 JSON
      apn*)     /usr/bin/mu300-modes apn "${act#apn:}" >/dev/null 2>&1; ifup wan >/dev/null 2>&1 & ;;
      5gran*)   /usr/bin/mu300-modes 5gran "${act#5gran:}" >/dev/null 2>&1 ;;
      speed*)   ( /usr/bin/mu300-speedtest > /tmp/mu300-speed.json.tmp 2>/dev/null && mv /tmp/mu300-speed.json.tmp /tmp/mu300-speed.json ) & ;;
    esac
  fi
  # ---- Ping 工具请求(对齐 UFI 的顶部 Ping)----
  if [ -f /tmp/mu300-tools.req ]; then
    req=$(head -1 /tmp/mu300-tools.req 2>/dev/null)
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
  # ---- 定时任务(UFI 格式):每分钟检查一次 ✓ ----
  MMNOW=$(date +%H:%M)
  if [ "$MMNOW" != "$LASTMINTASK" ]; then
    LASTMINTASK=$MMNOW
    /usr/bin/mu300-ufi-tasks.uc "$MMNOW" >/dev/null 2>&1
  fi

  # ---- 每 5 分钟读一次 APN(网页要用,不能在 CGI 里跑 AT ✓)----
  AT2=$(date +%s)
  ALT=$(cat /var/run/mu300-apn.ts 2>/dev/null)
  ALT=$((ALT+0))
  if [ $((AT2 - ALT)) -ge 300 ]; then
    date +%s > /var/run/mu300-apn.ts
    ( AO=$(mu300-at -t 10 "AT+CGDCONT?" 2>/dev/null | tr -d "\r" | grep -m1 "CGDCONT:")
      APN=$(printf "%s" "$AO" | awk -F',' '{print $3}' | tr -d '" ')
      PDP=$(printf "%s" "$AO" | awk -F',' '{print $2}' | tr -d '" ')
      printf '{"apn":"%s","pdp":"%s"}\n' "$APN" "$PDP" > /tmp/mu300-apn.json ) &
  fi

  # ---- 每 5 分钟读一次 LAN/DHCP 真实参数(避免网页写死)----
  LT2=$(date +%s)
  LLT=$(cat /var/run/mu300-lan.ts 2>/dev/null)
  LLT=$((LLT+0))
  if [ $((LT2 - LLT)) -ge 300 ]; then
    date +%s > /var/run/mu300-lan.ts
    (
      LIP=$(uci get network.lan.ipaddr 2>/dev/null)
      LNM=$(uci get network.lan.netmask 2>/dev/null)
      DST=$(uci get dhcp.lan.start 2>/dev/null)
      DLM=$(uci get dhcp.lan.limit 2>/dev/null)
      DLT=$(uci get dhcp.lan.leasetime 2>/dev/null)
      MTU=$(cat /sys/class/net/br-lan/mtu 2>/dev/null)
      printf '{"ip":"%s","netmask":"%s","start":"%s","limit":"%s","lease":"%s","mtu":"%s"}' \
        "$LIP" "$LNM" "$DST" "$DLM" "$DLT" "$MTU" > /tmp/mu300-lan.json
    ) &
  fi

  # ---- 开机首次运行:应用网页选的网络模式(★ 只在开机后 60 秒内做一次 ★)----
  #   为什么只在这时做:AT+SFUN=4/5 会断数据面 ✗(见 2026-09-27 07:4x 事故)
  #   开机时 PDP 还没建立,此时切换最安全 ✓
  UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  UP=$((UP+0))
  if [ "$UP" -lt 60 ] && [ ! -f /var/run/mu300-netmode.applied ]; then
    NM=$(cat /etc/mu300/net-mode 2>/dev/null)
    case "$NM" in
      Only_LTE)     mu300-at -t 12 'AT+SFUN=4' >/dev/null 2>&1; echo "$(date +%s) 应用 Only_LTE(AT+SFUN=4)" >> /tmp/ufi-netmode.log ;;
      WL_AND_5G)    mu300-at -t 12 'AT+SFUN=5' >/dev/null 2>&1; echo "$(date +%s) 应用 WL_AND_5G(AT+SFUN=5)" >> /tmp/ufi-netmode.log ;;
      *)            echo "$(date +%s) $NM 没有安全的切换方式,只存不切" >> /tmp/ufi-netmode.log ;;
    esac
    touch /var/run/mu300-netmode.applied
  fi

  sleep 4
done