#!/bin/sh
# MU300 / F50 数据灯(sc27xx:red=红, green=白灯芯, blue=蓝)
#
#  阶段 1(启动炫彩):红 → 白 → 蓝 循环;每一色用 LED 的 timer 触发器【快闪】(200ms 亮/200ms 灭),
#                     颜色每 1 秒切换一次 —— 这样既有快闪效果,又不需要亚秒级 sleep
#                     (busybox 的 sleep 不吃小数,usleep 也没编进来)
#  阶段 2(运行):5G = 白常亮 / 4G = 蓝常亮 / 无服务 = 红常亮
#
#  注意:用了 timer 触发器之后,brightness 写入会被内核忽略 —— 退出炫彩时必须先把 trigger 复位成 none
#  LED_DEMO=1 只跑约 12 秒炫彩就退出(演示用)
R=/sys/class/leds/sc27xx:red
W=/sys/class/leds/sc27xx:green
B=/sys/class/leds/sc27xx:blue
# 默认:每色【常亮】2 秒(看得清楚);想把某色改成快闪就把 LED_BLINK_MS 设成毫秒数(如 300)
INTERVAL=${LED_INTERVAL:-1}
BLINK_MS=${LED_BLINK_MS:-0}
DEMO=${LED_DEMO:-0}

set_led() { [ -w "$1/brightness" ] && echo "$2" > "$1/brightness" 2>/dev/null; return 0; }
trig_off() { for d in $R $W $B; do echo none > $d/trigger 2>/dev/null; echo 0 > $d/brightness 2>/dev/null; done; }
blink() {   # 让某一色快闪,其它两色灭
  # 顺序很重要:先把 trigger 设成 timer,内核才会创建 delay_on/delay_off 属性,
  # 否则写 delay_* 会报 "Permission denied"(踩过)
  for d in $R $W $B; do echo none > $d/trigger 2>/dev/null; echo 0 > $d/brightness 2>/dev/null; done
  if [ "$BLINK_MS" -gt 0 ] 2>/dev/null; then
    echo timer > $1/trigger 2>/dev/null
    echo $BLINK_MS > $1/delay_on 2>/dev/null
    echo $BLINK_MS > $1/delay_off 2>/dev/null
  else
    echo 255 > $1/brightness 2>/dev/null     # BLINK_MS=0 -> 常亮(不闪)
  fi
}
off()    { set_led $R 0; set_led $W 0; set_led $B 0; }
white()  { set_led $R 0; set_led $W 255; set_led $B 0; }
red()    { set_led $R 255; set_led $W 0; set_led $B 0; }
blue()   { set_led $R 0; set_led $W 0; set_led $B 255; }
wan_up() { ip -4 addr show sipa_eth0 2>/dev/null | grep -q 'inet '; }
rat() { sed -n 's/.*"rat": *"\([^"]*\)".*/\1/p' /tmp/mu300-status.json 2>/dev/null | head -1; }

# ---------- 阶段 1:炫彩(两种模式)----------
# 默认用 pattern 触发器做【ms 级追色】:红 400ms → 白 400ms → 蓝 400ms,无限循环,不占 CPU
#   (busybox 的 sleep 不吃小数、usleep 也没有,所以 shell 循环最快只能 1 秒一色;
#    pattern 触发器由内核驱动,能做到任意 ms —— 这是"再快一点"的正解)
# 想用旧的"shell 循环换色"就设 LED_USE_PATTERN=0
PATTERN_MS=${LED_PATTERN_MS:-400}
USE_PATTERN=${LED_USE_PATTERN:-1}

chase_start() {
  for d in $R $W $B; do echo none > $d/trigger 2>/dev/null; echo 0 > $d/brightness 2>/dev/null; done
  [ "$USE_PATTERN" = 1 ] || return 0
  /sbin/modprobe ledtrig-pattern 2>/dev/null
  echo pattern > $R/trigger 2>/dev/null
  echo "255 $PATTERN_MS 0 $((2*PATTERN_MS))" > $R/pattern 2>/dev/null
  echo pattern > $W/trigger 2>/dev/null
  echo "0 $PATTERN_MS 255 $PATTERN_MS 0 $PATTERN_MS" > $W/pattern 2>/dev/null
  echo pattern > $B/trigger 2>/dev/null
  echo "0 $((2*PATTERN_MS)) 255 $PATTERN_MS" > $B/pattern 2>/dev/null
}
chase_stop() {
  for d in $R $W $B; do echo none > $d/trigger 2>/dev/null; echo 0 > $d/brightness 2>/dev/null; done
}

# ---------- 阶段 1:炫彩 ----------
# 演示模式循环次数(默认 10 遍 ≈ 60 秒);正常启动时循环上限 30 遍,但网络一起来就提前退出
# 每轮循环是 1 秒(追色由内核 pattern 自己跑,shell 只负责"每秒看一眼网络起来没")
# 演示默认 180 秒;开机时最多 120 秒,但 5G 一起来立刻退出
CYCLES=${LED_DEMO_CYCLES:-120}
[ "$DEMO" = 1 ] && CYCLES=${LED_DEMO_CYCLES:-180}
if [ "$USE_PATTERN" = 1 ] && [ "$BLINK_MS" = 0 ]; then
    # 内核驱动追色:启动后只需每秒检查网络,不再自己换色
    chase_start
    n=0
    while [ $n -lt $CYCLES ]; do
        [ "$DEMO" = 1 ] || { wan_up && break; }
        sleep 1
        n=$((n+1))
    done
    chase_stop
else
    n=0
    while [ $n -lt $CYCLES ]; do
        blink $R; sleep $INTERVAL; [ "$DEMO" = 1 ] || { wan_up && break; }
        blink $W; sleep $INTERVAL; [ "$DEMO" = 1 ] || { wan_up && break; }
        blink $B; sleep $INTERVAL; [ "$DEMO" = 1 ] || { wan_up && break; }
        n=$((n+1))
    done
    trig_off
fi
[ "$DEMO" = 1 ] && exit 0

# ---------- 阶段 2:状态指示 ----------
last=''
while :; do
    if wan_up; then
        case "$(rat)" in
            5G*) st=white ;;
            4G*|LTE*) st=blue ;;
            *) st=white ;;
        esac
    else
        st=red
    fi
    [ "$st" != "$last" ] && { trig_off; $st; last=$st; }
    sleep 3
done